package com.wj.server.video.application;

import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;

import com.wj.server.config.VideoEditProperties;
import org.springframework.stereotype.Component;

@Component
public class FfmpegProcessor {
    private final VideoEditProperties properties;

    public FfmpegProcessor(VideoEditProperties properties) {
        this.properties = properties;
    }

    public void trim(Path input, Path output, long startMs, long endMs) {
        List<String> command = List.of(
            properties.ffmpegPath(), "-hide_banner", "-loglevel", "error", "-y",
            "-ss", seconds(startMs), "-i", input.toString(),
            "-t", seconds(endMs - startMs),
            "-c:v", "libx264", "-preset", "fast", "-c:a", "aac",
            "-movflags", "+faststart", output.toString());
        Process process = null;
        try {
            process = new ProcessBuilder(command)
                .redirectInput(ProcessBuilder.Redirect.PIPE)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();
            boolean finished = process.waitFor(properties.processTimeout().toMillis(), TimeUnit.MILLISECONDS);
            if (!finished) {
                process.destroyForcibly();
                throw new ProcessingException("FFMPEG_TIMEOUT");
            }
            if (process.exitValue() != 0 || !java.nio.file.Files.isRegularFile(output)) {
                throw new ProcessingException("FFMPEG_FAILED");
            }
        } catch (java.io.IOException exception) {
            throw new ProcessingException("FFMPEG_UNAVAILABLE");
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            if (process != null) {
                process.destroyForcibly();
            }
            throw new ProcessingException("FFMPEG_INTERRUPTED");
        }
    }

    private String seconds(long milliseconds) {
        return String.format(java.util.Locale.ROOT, "%.3f", milliseconds / 1000.0);
    }

    public static final class ProcessingException extends RuntimeException {
        private final String code;

        public ProcessingException(String code) {
            super(code);
            this.code = code;
        }

        public String code() {
            return code;
        }
    }
}
