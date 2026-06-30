import NIOCore
import NIOPosix
import NIOSSH
import Citadel

/// Relie deux canaux NIO bout à bout (pipe bidirectionnel avec backpressure).
/// Implémentation canonique « GlueHandler » des exemples SwiftNIO.
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(); let b = GlueHandler()
        a.partner = b; b.partner = a
        return (a, b)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}

enum PortForwarder {
    /// Démarre un forward local : écoute sur 127.0.0.1:localPort et relaie chaque
    /// connexion vers remoteHost:remotePort à travers le serveur SSH.
    /// Retourne le canal serveur (le fermer arrête le forward).
    static func startLocalForward(
        client: SSHClient,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Channel {
        let loop = client.eventLoop
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: localPort)

        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { localChannel in
                let promise = localChannel.eventLoop.makePromise(of: Void.self)
                let settings = SSHChannelType.DirectTCPIP(
                    targetHost: remoteHost, targetPort: remotePort, originatorAddress: originator)

                Task {
                    do {
                        let remoteChannel = try await client.createDirectTCPIPChannel(using: settings) { ch in
                            ch.setOption(ChannelOptions.autoRead, value: false)
                        }
                        let (g1, g2) = GlueHandler.matchedPair()
                        try await localChannel.pipeline.addHandler(g1).get()
                        try await remoteChannel.pipeline.addHandler(g2).get()
                        // Démarre la lecture une fois les deux côtés reliés.
                        localChannel.read()
                        remoteChannel.read()
                        promise.succeed(())
                    } catch {
                        localChannel.close(promise: nil)
                        promise.fail(error)
                    }
                }
                return promise.futureResult
            }

        return try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
    }
}
