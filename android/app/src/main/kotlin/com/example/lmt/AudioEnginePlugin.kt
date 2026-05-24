package com.example.lmt

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class AudioEnginePlugin(private val context: Context) {
    companion object {
        private const val CHANNEL = "com.example.lmt/audio"
        private const val TAG = "LMT_AudioEngine"
        private var nativeHandle: Long = 0
        private var methodChannel: MethodChannel? = null

        init {
            System.loadLibrary("lmt_audio")
        }

        fun setup(flutterEngine: FlutterEngine, context: Context) {
            val plugin = AudioEnginePlugin(context)
            plugin.setupMethodChannel(flutterEngine)
        }
    }

    private fun setupMethodChannel(flutterEngine: FlutterEngine) {
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    nativeHandle = nativeCreate()
                    val opened = nativeOpen(nativeHandle)
                    val started = if (opened) nativeStart(nativeHandle) else false
                    result.success(started)
                }
                "release" -> {
                    nativeStop(nativeHandle)
                    nativeClose(nativeHandle)
                    nativeDestroy(nativeHandle)
                    result.success(true)
                }
                "loadSample" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val path = call.argument<String>("path") ?: ""
                    val success = nativeLoadSample(nativeHandle, instrumentIdx, path)
                    result.success(success)
                }
                "clearSample" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    nativeClearSample(nativeHandle, instrumentIdx)
                    result.success(true)
                }
                "noteOn" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val frequency = call.argument<Double>("frequency")?.toFloat() ?: 440f
                    val level = call.argument<Double>("level")?.toFloat() ?: 0.8f
                    nativeNoteOn(nativeHandle, instrumentIdx, frequency, level)
                    result.success(true)
                }
                "noteOnRegion" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val frequency = call.argument<Double>("frequency")?.toFloat() ?: 440f
                    val level = call.argument<Double>("level")?.toFloat() ?: 0.8f
                    val startNorm = call.argument<Double>("startNorm")?.toFloat() ?: 0f
                    val endNorm = call.argument<Double>("endNorm")?.toFloat() ?: 1f
                    val attackTime = call.argument<Double>("attackTime")?.toFloat() ?: 0f
                    val releaseTime = call.argument<Double>("releaseTime")?.toFloat() ?: 0.05f
                    val loopMode = call.argument<Int>("loopMode") ?: 0
                    nativeNoteOnRegion(nativeHandle, instrumentIdx, frequency, level, startNorm, endNorm, attackTime, releaseTime, loopMode)
                    result.success(true)
                }
                "noteOff" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    nativeNoteOff(nativeHandle, instrumentIdx)
                    result.success(true)
                }
                "stopAll" -> {
                    nativeStopAll(nativeHandle)
                    result.success(true)
                }
                "isPlaying" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val playing = nativeIsPlaying(nativeHandle, instrumentIdx)
                    result.success(playing)
                }
                "setLevel" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val level = call.argument<Double>("level")?.toFloat() ?: 0.8f
                    nativeSetLevel(nativeHandle, instrumentIdx, level)
                    result.success(true)
                }
                "setPan" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val pan = call.argument<Double>("pan")?.toFloat() ?: 0.5f
                    nativeSetPan(nativeHandle, instrumentIdx, pan)
                    result.success(true)
                }
                "updateStretch" -> {
                    val instrumentIdx = call.argument<Int>("instrumentIdx") ?: -1
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val beats = call.argument<Int>("beats") ?: 4
                    val bpm = call.argument<Double>("bpm")?.toFloat() ?: 120f
                    val preservePitch = call.argument<Boolean>("preservePitch") ?: true
                    nativeUpdateStretch(nativeHandle, instrumentIdx, enabled, beats, bpm, preservePitch)
                    result.success(true)
                }
                "enqueueAllRows" -> {
                    val loop = call.argument<Boolean>("loop") ?: false
                    val rowDataList = call.argument<List<Int>>("rowData") ?: emptyList()
                    val rowDataArray = rowDataList.toIntArray()
                    nativeEnqueueAllRows(nativeHandle, loop, rowDataArray)
                    result.success(true)
                }
                "consumeRowAdvances" -> {
                    val advances = nativeConsumeRowAdvances(nativeHandle)
                    result.success(advances)
                }
                "clearQueue" -> {
                    nativeClearQueue(nativeHandle)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        Log.d(TAG, "AudioEngine MethodChannel setup complete")
    }

    // Native methods
    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeOpen(handle: Long): Boolean
    private external fun nativeClose(handle: Long)
    private external fun nativeStart(handle: Long): Boolean
    private external fun nativeStop(handle: Long)
    private external fun nativeLoadSample(handle: Long, instrumentIdx: Int, path: String): Boolean
    private external fun nativeClearSample(handle: Long, instrumentIdx: Int)
    private external fun nativeNoteOn(handle: Long, instrumentIdx: Int, frequency: Float, level: Float)
    private external fun nativeNoteOnRegion(handle: Long, instrumentIdx: Int, frequency: Float, level: Float, startNorm: Float, endNorm: Float, attackTime: Float, releaseTime: Float, loopMode: Int)
    private external fun nativeNoteOff(handle: Long, instrumentIdx: Int)
    private external fun nativeStopAll(handle: Long)
    private external fun nativeIsPlaying(handle: Long, instrumentIdx: Int): Boolean
    private external fun nativeSetLevel(handle: Long, instrumentIdx: Int, level: Float)
    private external fun nativeSetPan(handle: Long, instrumentIdx: Int, pan: Float)
    private external fun nativeUpdateStretch(handle: Long, instrumentIdx: Int, enabled: Boolean, beats: Int, bpm: Float, preservePitch: Boolean)
    private external fun nativeEnqueueAllRows(handle: Long, loop: Boolean, rowData: IntArray)
    private external fun nativeConsumeRowAdvances(handle: Long): Int
    private external fun nativeClearQueue(handle: Long)
}
