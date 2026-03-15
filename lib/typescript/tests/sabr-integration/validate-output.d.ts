/**
 * Validates a downloaded SABR output file.
 * Checks file size and optionally probes with ffprobe for codec/duration info.
 */
export interface ValidationResult {
    fileSizeBytes: number;
    durationSeconds?: number;
    codec?: string;
    valid: boolean;
    error?: string;
}
export declare function validateOutput(filePath: string): Promise<ValidationResult>;
//# sourceMappingURL=validate-output.d.ts.map