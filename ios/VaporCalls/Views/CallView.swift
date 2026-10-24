import SwiftUI
@preconcurrency import WebRTC

struct CallView: View {
    let calls: CallManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let call = calls.call {
                CallContent(calls: calls, call: call)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct CallContent: View {
    let calls: CallManager
    let call: CallManager.ActiveCall

    private var showsRemoteVideo: Bool {
        call.video && call.phase == .active && calls.remoteVideoTrack != nil
    }

    private var showsLocalPreview: Bool {
        call.video && call.phase != .incoming && !calls.cameraOff && calls.localVideoTrack != nil
    }

    var body: some View {
        ZStack {
            if showsRemoteVideo, let remote = calls.remoteVideoTrack {
                VideoTrackView(track: remote)
                    .ignoresSafeArea()
            } else {
                RadialGradient(colors: [Color(white: 0.2), .black], center: .init(x: 0.5, y: 0.3), startRadius: 10, endRadius: 500)
                    .ignoresSafeArea()
                Avatar(name: call.peerName, pulsing: call.phase == .incoming || call.phase == .ringing)
                    .offset(y: -40)
            }

            if showsLocalPreview, let local = calls.localVideoTrack {
                VideoTrackView(track: local, mirrored: calls.usingFrontCamera)
                    .frame(width: 112, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.3), lineWidth: 1.5))
                    .shadow(radius: 8)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack(spacing: 0) {
                CallHeader(call: call, leavesRoomForPreview: showsLocalPreview)
                Spacer()
                if call.phase == .incoming {
                    IncomingControls(calls: calls, video: call.video)
                } else {
                    InCallControls(calls: calls, video: call.video)
                }
            }
            .padding(.bottom, 24)
        }
    }
}

private struct CallHeader: View {
    let call: CallManager.ActiveCall
    let leavesRoomForPreview: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(call.peerName)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(status(at: context.date))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 6)
        .padding(.top, 24)
        // Keep the name clear of the self-preview in the top-right corner.
        .padding(.horizontal, leavesRoomForPreview ? 140 : 24)
        .frame(maxWidth: .infinity)
    }

    private func status(at date: Date) -> String {
        switch call.phase {
        case .dialing:
            return "Вызов…"
        case .ringing:
            return "Звонит на \(call.ringingDevices ?? 1) устр.…"
        case .incoming:
            return "\(call.video ? "Видеозвонок" : "Аудиозвонок")\(call.peerDevice.map { " · \($0)" } ?? "")"
        case .connecting:
            return call.trouble == .reconnecting ? "Восстанавливаем звонок…" : "Соединение…"
        case .active:
            if call.trouble == .reconnecting { return "Переподключение…" }
            if call.trouble == .poorNetwork { return "Плохая связь…" }
            let seconds = date.timeIntervalSince(call.connectedAt ?? date)
            return Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
        }
    }
}

private struct Avatar: View {
    let name: String
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 128, height: 128)
            .background(Circle().fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .background(
                Circle()
                    .stroke(Color.green.opacity(pulsing ? 0.5 : 0), lineWidth: 2)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

private struct IncomingControls: View {
    let calls: CallManager
    let video: Bool

    var body: some View {
        HStack(spacing: 72) {
            RoundButton(systemImage: "xmark", label: "Отклонить", tint: .red) { calls.decline() }
            RoundButton(systemImage: video ? "video.fill" : "phone.fill", label: "Ответить", tint: .green) {
                Task { await calls.accept() }
            }
        }
    }
}

private struct InCallControls: View {
    let calls: CallManager
    let video: Bool

    var body: some View {
        HStack(spacing: 20) {
            RoundButton(systemImage: calls.muted ? "mic.slash.fill" : "mic.fill", toggled: calls.muted) { calls.toggleMute() }
                .accessibilityLabel(calls.muted ? "Включить микрофон" : "Выключить микрофон")
            if video {
                RoundButton(systemImage: calls.cameraOff ? "video.slash.fill" : "video.fill", toggled: calls.cameraOff) { calls.toggleCamera() }
                    .accessibilityLabel(calls.cameraOff ? "Включить камеру" : "Выключить камеру")
                RoundButton(systemImage: "arrow.triangle.2.circlepath.camera.fill") { calls.flipCamera() }
                    .accessibilityLabel("Сменить камеру")
            }
            RoundButton(systemImage: "phone.down.fill", tint: .red) { calls.hangup() }
                .accessibilityLabel("Завершить звонок")
        }
    }
}

private struct RoundButton: View {
    let systemImage: String
    var label: String?
    var tint: Color?
    var toggled = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(toggled ? .black : .white)
                    .frame(width: 66, height: 66)
                    .background {
                        if let tint {
                            Circle().fill(tint)
                        } else if toggled {
                            Circle().fill(.white)
                        } else {
                            Circle().fill(.ultraThinMaterial)
                        }
                    }
            }
            if let label {
                Text(label).font(.footnote).foregroundStyle(.white)
            }
        }
    }
}

/// Renders a WebRTC video track with Metal.
struct VideoTrackView: UIViewRepresentable {
    let track: RTCVideoTrack
    var mirrored = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        track.add(view)
        context.coordinator.track = track
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track.add(view)
            context.coordinator.track = track
        }
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
