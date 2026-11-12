package io.github.ichaivalx.unison.capture

/**
 * 一次 `dumpsys media.audio_flinger` 中的输出线程与其上的播放轨道。输出通道以输出 flags（如
 * `PRIMARY|FAST`、`DEEP_BUFFER`）标识，重启后不变；io 编号只在本次开机内唯一。
 */
internal class AudioOutputs private constructor(val channels: Map<Int, String>, val tracks: List<Track>) {
    class Track(val pid: Int, val uid: Int, val session: Int, val usage: Int, val active: Boolean, val io: Int)

    /** 会话的轨道所在的输出线程；同一会话有多条轨道时取活跃的 */
    fun ioOf(session: Int): Int? = tracks.filter { it.session == session }.maxByOrNull { it.active }?.io

    companion object {
        private val ioLine = Regex("""^\s*I/O handle: (\d+)""")
        private val flagsLine = Regex("""^\s*AudioStreamOut: \S+ flags (0x[0-9a-fA-F]+)(?: \((.*)\))?""")
        private val flagName = Regex("""AUDIO_OUTPUT_FLAG_([A-Z0-9_]+)""")
        // Track::appendDump：类型与编号、Active、pid/uid、Session、Port、状态、cblk flags、格式、声道、
        // 采样率、流类型、用途（十六进制）
        private val trackLine = Regex("""^\s*(?:F\d+\s+)?(?:[SP?]\s+)?\d+\s+(yes|no)\s+(\d+)\s*/\s*(\d+)\s+(\d+)\s+\d+\s+\S+\s+0x[0-9a-fA-F]+\s+\S+\s+\S+\s+\d+\s+\d+\s+([0-9a-fA-F]+)\s+""")

        fun read(): AudioOutputs {
            val channels = mutableMapOf<Int, String>()
            val tracks = mutableListOf<Track>()
            val dump = ProcessBuilder("dumpsys", "media.audio_flinger").redirectErrorStream(true).start()
            var output = false
            var io: Int? = null
            dump.inputStream.bufferedReader().useLines { lines -> lines.forEach { line ->
                if (line.startsWith("Output thread ")) { output = true; io = null }
                if (line.trim() == "Local log:" || line.startsWith("Input thread ")) output = false
                if (!output) return@forEach
                ioLine.find(line)?.let { io = it.groupValues[1].toInt(); return@forEach }
                val current = io ?: return@forEach
                flagsLine.find(line)?.let { match ->
                    val names = flagName.findAll(match.groupValues[2]).map { it.groupValues[1] }.toList()
                    channels[current] = names.joinToString("|").ifEmpty { match.groupValues[1] }
                    return@forEach
                }
                trackLine.find(line)?.let { match ->
                    tracks.add(Track(pid = match.groupValues[2].toInt(), uid = match.groupValues[3].toInt(),
                        session = match.groupValues[4].toInt(), usage = match.groupValues[5].toInt(16),
                        active = match.groupValues[1] == "yes", io = current))
                }
            } }
            dump.waitFor()
            return AudioOutputs(channels, tracks)
        }
    }
}
