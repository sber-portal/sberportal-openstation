package com.openstation.launcher

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Window
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Auto brightness for SberPortal.
 *
 * The portal has a single ambient light sensor (ltr381, android.sensor.light) and no
 * vendor brightness service of its own, so the launcher drives the backlight: a
 * lux -> brightness curve plus a "dark room" state that lets the launcher collapse
 * into a minimal clock screen.
 *
 * The sensor reports on-change only, so we do not average forever: each event settles
 * on a value after a short debounce, and large jumps (someone switched the lights on)
 * are applied at once.
 *
 * Brightness is written to Settings.System so it survives across apps and video players
 * stay dim at night. Without WRITE_SETTINGS we fall back to the window brightness.
 */
class AmbientDisplay(
    private val context: Context,
    private val window: Window,
    private val onNightChanged: (Boolean) -> Unit
) : SensorEventListener {

    companion object {
        private const val TAG = "AmbientDisplay"

        /** Brightness range we allow ourselves, 0..255 (the panel max is 255). */
        private const val MIN_BRIGHTNESS = 14
        private const val MAX_BRIGHTNESS = 245

        /** Below this illuminance the room counts as dark; above the exit value it stops. */
        private const val NIGHT_ENTER_LUX = 9.0
        private const val NIGHT_EXIT_LUX = 18.0

        /** lux -> brightness curve, piecewise linear in log10(lux). */
        private val CURVE = doubleArrayOf(
            0.0, 12.0,      // pitch black
            6.0, 40.0,      // night light / screen glow
            40.0, 85.0,     // dim evening room
            150.0, 150.0,   // normal living room light
            400.0, 190.0,   // bright room
            1000.0, 220.0,  // daylight
            3000.0, MAX_BRIGHTNESS.toDouble()
        )

        private const val SENSOR_INTERVAL_US = 500_000
        private const val SETTLE_MS = 400L
        private const val BIG_JUMP = 25
    }

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val handler = Handler(Looper.getMainLooper())
    private var lightSensor: Sensor? = null
    private var running = false

    var enabled = true
    var lux = -1.0
        private set
    var nightMode = false
        private set
    var appliedBrightness = -1
        private set

    private var canWriteSettings = false

    private val settleRunnable = Runnable {
        if (lux >= 0.0) apply(brightnessFor(lux), force = true)
    }

    /**
     * ltr381 reports "on-change", so a freshly started launcher can wait a long time for
     * its first sample in a room whose light is not changing. The IIO channels are world
     * readable, so use them for a first approximation until the HAL sends a real value.
     */
    private val firstSampleCheck = Runnable {
        if (lux >= 0.0) return@Runnable
        val raw = readSysfsLux()
        if (raw >= 0.0) {
            Log.i(TAG, "no sensor sample yet, sysfs estimate ${String.format("%.1f", raw)} lux")
            onReading(raw)
        } else {
            Log.w(TAG, "no sensor sample and sysfs is not readable")
        }
    }

    private fun readSysfsLux(): Double {
        val dir = File("/sys/bus/iio/devices/iio:device0")
        fun channel(name: String): Double = try {
            File(dir, name).readText().trim().toDouble()
        } catch (_: Throwable) {
            -1.0
        }
        val r = channel("in_intensity_red_raw")
        val g = channel("in_intensity_green_raw")
        val b = channel("in_intensity_blue_raw")
        if (r < 0.0 || g < 0.0 || b < 0.0) return -1.0
        // Crude but monotonic: matches the HAL closely enough at the night threshold.
        return maxOf(0.0, 0.7 * r + 1.0 * g + 0.35 * b) * 1.25
    }

    fun start() {
        if (running) {
            applyCurrent(force = true)
            return
        }
        val sm = sensorManager ?: return
        if (lightSensor == null) lightSensor = sm.getDefaultSensor(Sensor.TYPE_LIGHT)
        val sensor = lightSensor
        if (sensor == null) {
            Log.w(TAG, "no light sensor on this device, auto brightness disabled")
            return
        }
        canWriteSettings = Settings.System.canWrite(context)
        running = sm.registerListener(this, sensor, SENSOR_INTERVAL_US)
        Log.i(TAG, "started: sensor='${sensor.name}' writeSettings=$canWriteSettings")
        handler.removeCallbacks(firstSampleCheck)
        handler.postDelayed(firstSampleCheck, 2_000L)
    }

    fun stop() {
        if (!running) return
        running = false
        handler.removeCallbacks(settleRunnable)
        try {
            sensorManager?.unregisterListener(this)
        } catch (_: Throwable) {
        }
    }

    /** Re-apply the last known brightness when the launcher comes back to the foreground. */
    fun applyCurrent(force: Boolean = false) {
        if (!enabled || lux < 0.0) return
        apply(brightnessFor(lux), force)
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_LIGHT) return
        val raw = event.values.firstOrNull()?.toDouble() ?: return
        if (raw < 0.0) return
        onReading(raw)
    }

    private fun onReading(raw: Double) {
        // Light averaging only to reject single-frame flicker: the sensor is on-change,
        // so waiting for more samples would leave the screen at a stale brightness.
        lux = if (lux < 0.0) raw else (lux * 0.5 + raw * 0.5)

        val dark = if (nightMode) lux < NIGHT_EXIT_LUX else lux < NIGHT_ENTER_LUX
        val nightFlipped = dark != nightMode
        if (nightFlipped) {
            nightMode = dark
            Log.i(TAG, "night mode ${if (dark) "on" else "off"} (lux=${String.format("%.1f", lux)})")
            handler.post { onNightChanged(dark) }
        }

        val target = brightnessFor(lux)
        if (nightFlipped || appliedBrightness < 0 || abs(target - appliedBrightness) >= BIG_JUMP) {
            apply(target, force = true)
        }
        handler.removeCallbacks(settleRunnable)
        handler.postDelayed(settleRunnable, SETTLE_MS)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun brightnessFor(value: Double): Int {
        val logLux = Math.log10(maxOf(value, 0.0) + 1.0)
        var out = CURVE[1]
        var i = 2
        var prevLog = Math.log10(CURVE[0] + 1.0)
        while (i < CURVE.size) {
            val curLog = Math.log10(CURVE[i] + 1.0)
            if (logLux <= curLog) {
                val t = ((logLux - prevLog) / (curLog - prevLog)).coerceIn(0.0, 1.0)
                out = CURVE[i - 1] + (CURVE[i + 1] - CURVE[i - 1]) * t
                break
            }
            out = CURVE[i + 1]
            prevLog = curLog
            i += 2
        }
        return out.roundToInt().coerceIn(MIN_BRIGHTNESS, MAX_BRIGHTNESS)
    }

    private fun apply(target: Int, force: Boolean) {
        if (!enabled) return
        if (!force && target == appliedBrightness) return
        if (target == appliedBrightness) return
        appliedBrightness = target

        var wrote = false
        if (canWriteSettings) {
            wrote = try {
                val cr = context.contentResolver
                val mode = Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, 0)
                if (mode != Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL) {
                    Settings.System.putInt(
                        cr,
                        Settings.System.SCREEN_BRIGHTNESS_MODE,
                        Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
                    )
                }
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, target)
            } catch (t: Throwable) {
                Log.w(TAG, "system brightness write failed: ${t.message}")
                false
            }
        }
        if (!wrote) {
            try {
                val attrs = window.attributes
                attrs.screenBrightness = (target / 255f).coerceIn(0.02f, 1f)
                window.attributes = attrs
            } catch (t: Throwable) {
                Log.w(TAG, "window brightness failed: ${t.message}")
            }
        }
        Log.i(TAG, "brightness -> $target (lux=${String.format("%.1f", lux)}, night=$nightMode)")
    }
}
