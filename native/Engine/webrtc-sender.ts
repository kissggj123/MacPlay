/**
 * WebRTC video sender for CarPlay, ported from WheelPlay.
 *
 * Takes H.264/H.265 NAL units from the iPhone (via the Rust forwarder)
 * and streams them to browsers via WebRTC (libdatachannel).
 *
 * Signaling is done over the existing WebSocket control channel.
 */

import { appendNals, packetizeVideo, isKeyframe, getNalType } from './webrtc-packetizer.js';

// node-datachannel is an optional dependency (installed via npm)
let RTCPeerConnection: any = null;
let RTCSessionDescription: any = null;
try {
  const dc = await import('node-datachannel');
  RTCPeerConnection = dc.PeerConnection;
  RTCSessionDescription = dc.SessionDescription;
} catch (e) {
  console.error('[webrtc] node-datachannel not available:', e);
}

export interface WebRTCConfig {
  codec: 'h264' | 'h265';
  sps?: Uint8Array; // H.264 SPS or H.265 SPS
  pps?: Uint8Array; // H.264 PPS or H.265 PPS
  vps?: Uint8Array; // H.265 VPS only
}

export class WebRTCVideoSender {
  private pc: any = null;
  private track: any = null;
  private config: WebRTCConfig;
  private sequenceNumber = 0;
  private timestamp = 0;
  private ssrc = 42;
  private onSignalingMessage: (msg: object) => void;

  constructor(config: WebRTCConfig, onSignalingMessage: (msg: object) => void) {
    this.config = config;
    this.onSignalingMessage = onSignalingMessage;
  }

  /**
   * Create the PeerConnection and generate an SDP offer.
   * The offer is sent via onSignalingMessage, the browser responds with an answer.
   */
  async createOffer(): Promise<void> {
    if (!RTCPeerConnection) {
      throw new Error('node-datachannel not available');
    }

    this.pc = new RTCPeerConnection({
      iceServers: [],
      // WheelPlay: host candidates only (LAN), no STUN/TURN
    });

    // Create video track
    const codec = this.config.codec === 'h265' ? 'video/h265' : 'video/h264';
    this.track = this.pc.addTrack({
      kind: 'video',
      codec,
      payloadType: 96,
      ssrc: this.ssrc,
      clockRate: 90000,
    });

    // Set up event handlers
    this.pc.onLocalDescription = (sdp: string, type: string) => {
      // WheelPlay: disable auto-negotiation, manual SDP
      this.onSignalingMessage({
        type: 'rtc-offer',
        codec: this.config.codec.toUpperCase(),
        sdp,
      });
    };

    this.pc.onLocalCandidate = (candidate: string, mid: string) => {
      // Host candidates only, gathered quickly
    };

    this.pc.onStateChange = (state: string) => {
      console.error(`[webrtc] PeerConnection state: ${state}`);
    };

    // Generate offer
    // Note: node-datachannel API may differ, adjust as needed
  }

  /**
   * Handle SDP answer from browser.
   */
  async handleAnswer(sdp: string): Promise<void> {
    if (!this.pc) throw new Error('PeerConnection not created');
    // Set remote description
    // Note: WheelPlay requires browser to be DTLS server (a=setup:passive)
    // The browser-side JS handles this via SDP rewrite
  }

  /**
   * Send a video frame (Annex B NAL units) via WebRTC.
   * @param frame - Complete Annex B access unit
   */
  sendFrame(frame: Uint8Array): void {
    if (!this.track) return;

    const hevc = this.config.codec === 'h265';

    // Build parameters (VPS/SPS/PPS) for keyframes
    let parameters: Uint8Array | null = null;
    const nals = appendNals(frame, hevc);
    const hasKeyframe = nals.some(nal => isKeyframe(nal.data, hevc));

    if (hasKeyframe) {
      // Prepend parameter sets for keyframes (WheelPlay behavior)
      const paramNals: Uint8Array[] = [];
      if (hevc && this.config.vps) {
        paramNals.push(this.addStartCode(this.config.vps));
        paramNals.push(this.addStartCode(this.config.sps!));
        paramNals.push(this.addStartCode(this.config.pps!));
      } else if (!hevc && this.config.sps) {
        paramNals.push(this.addStartCode(this.config.sps));
        paramNals.push(this.addStartCode(this.config.pps!));
      }
      if (paramNals.length > 0) {
        const totalLen = paramNals.reduce((sum, n) => sum + n.length, 0);
        parameters = new Uint8Array(totalLen);
        let offset = 0;
        for (const n of paramNals) {
          parameters.set(n, offset);
          offset += n.length;
        }
      }
    }

    // Packetize
    const packets = packetizeVideo(frame, parameters, hevc, 1100);

    // Send via WebRTC
    // Note: This is simplified. Actual implementation needs to construct
    // RTP packets and send via node-datachannel's track.
    // See WheelPlay's video_rtp_handler for the full implementation.
    for (const pkt of packets) {
      this.sendRtpPacket(pkt.fuHeader, pkt.payload, pkt.isLast);
    }

    // Increment timestamp (90kHz clock, ~33ms per frame at 30fps)
    this.timestamp += 3000;
  }

  private addStartCode(nal: Uint8Array): Uint8Array {
    const out = new Uint8Array(4 + nal.length);
    out[0] = 0; out[1] = 0; out[2] = 0; out[3] = 1;
    out.set(nal, 4);
    return out;
  }

  private sendRtpPacket(fuHeader: Uint8Array, payload: Uint8Array, marker: boolean): void {
    // Construct RTP packet:
    // 0: Version(2) | Padding(0) | Extension(0) | CSRC(0) = 0x80
    // 1: Marker | Payload Type (96)
    // 2-3: Sequence number
    // 4-7: Timestamp (90kHz)
    // 8-11: SSRC
    // 12+: FU header + payload

    const rtpHeaderLen = 12;
    const packetLen = rtpHeaderLen + fuHeader.length + payload.length;
    const packet = new Uint8Array(packetLen);

    packet[0] = 0x80; // Version 2
    packet[1] = (marker ? 0x80 : 0x00) | 96; // Marker + PT 96
    packet[2] = (this.sequenceNumber >> 8) & 0xff;
    packet[3] = this.sequenceNumber & 0xff;
    packet[4] = (this.timestamp >> 24) & 0xff;
    packet[5] = (this.timestamp >> 16) & 0xff;
    packet[6] = (this.timestamp >> 8) & 0xff;
    packet[7] = this.timestamp & 0xff;
    packet[8] = (this.ssrc >> 24) & 0xff;
    packet[9] = (this.ssrc >> 16) & 0xff;
    packet[10] = (this.ssrc >> 8) & 0xff;
    packet[11] = this.ssrc & 0xff;

    let offset = rtpHeaderLen;
    if (fuHeader.length > 0) {
      packet.set(fuHeader, offset);
      offset += fuHeader.length;
    }
    packet.set(payload, offset);

    this.sequenceNumber = (this.sequenceNumber + 1) & 0xffff;

    // Send via node-datachannel
    // TODO: Actual send via track
    if (this.track && this.track.send) {
      this.track.send(packet);
    }
  }

  close(): void {
    if (this.pc) {
      this.pc.close();
      this.pc = null;
      this.track = null;
    }
  }
}
