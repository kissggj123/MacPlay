/**
 * RTP packetizer for H.264/H.265, ported from WheelPlay's video_packetizer.hpp.
 *
 * Takes complete Annex B NAL units and packetizes them into RTP packets
 * according to RFC 6184 (H.264) and RFC 7798 (H.265).
 */

export interface NalView {
  data: Uint8Array;
  size: number;
}

export interface RtpPacket {
  fuHeader: Uint8Array; // Empty for single NAL, 2-3 bytes for FU-A/FU
  payload: Uint8Array;
  isLast: boolean; // Set RTP marker bit
}

/**
 * Split Annex B byte stream into NAL unit views.
 * Throws on malformed input.
 */
export function appendNals(input: Uint8Array, hevc: boolean): NalView[] {
  const result: NalView[] = [];
  if (input.length === 0) return result;

  const prefixLen = (i: number): number => {
    if (i + 3 > input.length || input[i] !== 0 || input[i + 1] !== 0) return 0;
    if (input[i + 2] === 1) return 3;
    return (i + 4 <= input.length && input[i + 2] === 0 && input[i + 3] === 1) ? 4 : 0;
  };

  let i = 0;
  while (i < input.length && prefixLen(i) === 0) {
    if (input[i] !== 0) throw new Error('Expected Annex B video');
    i++;
  }
  if (i === input.length) throw new Error('Missing NAL start code');

  while (i < input.length) {
    const start = i + prefixLen(i);
    i = start;
    while (i < input.length && prefixLen(i) === 0) i++;
    const size = i - start;
    if (size < (hevc ? 2 : 1)) throw new Error('Truncated NAL header');
    result.push({ data: input.subarray(start, i), size });
  }
  return result;
}

/**
 * Packetize a video frame (Annex B) into RTP packets.
 * @param frame - Complete Annex B access unit
 * @param parameters - Optional Annex B parameter sets (VPS/SPS/PPS)
 * @param hevc - True for H.265, false for H.264
 * @param maxPayload - Max RTP payload size (e.g., 1100)
 */
export function packetizeVideo(
  frame: Uint8Array,
  parameters: Uint8Array | null,
  hevc: boolean,
  maxPayload: number = 1100
): RtpPacket[] {
  if (frame.length === 0 || maxPayload < 4) {
    throw new Error('Invalid video packetization input');
  }

  const nals: NalView[] = [];
  if (parameters && parameters.length > 0) {
    nals.push(...appendNals(parameters, hevc));
  }
  nals.push(...appendNals(frame, hevc));

  const packets: RtpPacket[] = [];

  for (let idx = 0; idx < nals.length; idx++) {
    const nal = nals[idx];
    const isLastNal = idx === nals.length - 1;

    if (nal.size <= maxPayload) {
      // Single NAL unit packet
      packets.push({
        fuHeader: new Uint8Array(0),
        payload: nal.data,
        isLast: isLastNal,
      });
      continue;
    }

    // Fragmentation
    const nalHeaderLen = hevc ? 2 : 1;
    const fuHeaderLen = hevc ? 3 : 2;
    const capacity = maxPayload - fuHeaderLen;
    const nalType = hevc
      ? (nal.data[0] >> 1) & 0x3f
      : nal.data[0] & 0x1f;

    for (let offset = nalHeaderLen; offset < nal.size;) {
      const size = Math.min(capacity, nal.size - offset);
      const isStart = offset === nalHeaderLen;
      const isEnd = offset + size === nal.size;

      const header = new Uint8Array(fuHeaderLen);
      if (hevc) {
        // H.265 FU (RFC 7798): type 49
        header[0] = (nal.data[0] & 0x81) | (49 << 1);
        header[1] = nal.data[1]; // Preserve layer/temporal ID
        header[2] = nalType | (isStart ? 0x80 : 0) | (isEnd ? 0x40 : 0);
      } else {
        // H.264 FU-A (RFC 6184): type 28
        header[0] = (nal.data[0] & 0xe0) | 28;
        header[1] = nalType | (isStart ? 0x80 : 0) | (isEnd ? 0x40 : 0);
      }

      packets.push({
        fuHeader: header,
        payload: nal.data.subarray(offset, offset + size),
        isLast: isLastNal && isEnd,
      });

      offset += size;
    }
  }

  return packets;
}

/**
 * Get NAL unit type from Annex B NAL data (without start code).
 */
export function getNalType(nal: Uint8Array, hevc: boolean): number {
  if (nal.length === 0) return -1;
  if (hevc) {
    return nal.length >= 2 ? (nal[0] >> 1) & 0x3f : -1;
  } else {
    return nal[0] & 0x1f;
  }
}

/**
 * Check if NAL is a keyframe (IDR).
 */
export function isKeyframe(nal: Uint8Array, hevc: boolean): boolean {
  const type = getNalType(nal, hevc);
  if (hevc) {
    // H.265 IDR: 19 (IDR_W_RADL), 20 (IDR_N_LP)
    return type === 19 || type === 20;
  } else {
    // H.264 IDR: 5
    return type === 5;
  }
}
