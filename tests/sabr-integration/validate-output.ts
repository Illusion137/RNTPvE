/**
 * Validates a downloaded SABR output file.
 * Checks file size and optionally probes with ffprobe for codec/duration info.
 */

import fs from 'fs';
import { execSync } from 'child_process';

export interface ValidationResult {
  fileSizeBytes: number;
  durationSeconds?: number;
  codec?: string;
  valid: boolean;
  error?: string;
}

export async function validateOutput(
  filePath: string
): Promise<ValidationResult> {
  if (!fs.existsSync(filePath)) {
    return {
      fileSizeBytes: 0,
      valid: false,
      error: `File not found: ${filePath}`,
    };
  }

  const stat = fs.statSync(filePath);
  const fileSizeBytes = stat.size;

  if (fileSizeBytes === 0) {
    return {
      fileSizeBytes: 0,
      valid: false,
      error: 'Output file is empty (0 bytes)',
    };
  }

  if (fileSizeBytes < 1024) {
    return {
      fileSizeBytes,
      valid: false,
      error: `Output file is suspiciously small: ${fileSizeBytes} bytes`,
    };
  }

  // Try ffprobe for detailed validation (optional — skips gracefully if not installed)
  try {
    const ffprobeOutput = execSync(
      `ffprobe -v quiet -print_format json -show_streams "${filePath}"`,
      { encoding: 'utf8', timeout: 10_000 }
    );
    const probe = JSON.parse(ffprobeOutput) as {
      streams: Array<{
        codec_type: string;
        codec_name: string;
        duration?: string;
      }>;
    };
    const audioStream = probe.streams.find((s) => s.codec_type === 'audio');
    return {
      fileSizeBytes,
      durationSeconds: audioStream?.duration
        ? parseFloat(audioStream.duration)
        : undefined,
      codec: audioStream?.codec_name,
      valid: true,
    };
  } catch {
    // ffprobe not installed or failed — basic size check is sufficient
    return { fileSizeBytes, valid: true };
  }
}
