// station_highlight.gdshader
// Attach to a ColorRect sized and centred over a single 32x32 station tile.
// render_mode blend_add: glows on top of the sprite without obscuring it.
//
// Driven from GDScript:
//   mat.set_shader_parameter("is_active", true/false)   // instant on/off
//   mat.set_shader_parameter("intensity", 0.0..1.0)     // tweened for pulsing
//   mat.set_shader_parameter("glow_color", Color(...))  // swap green→red for broken
shader_type canvas_item;
render_mode blend_add;

uniform bool  is_active                          = false;
uniform float intensity  : hint_range(0.0, 1.0) = 1.0;
uniform vec4  glow_color : source_color          = vec4(0.08, 0.45, 1.0, 1.0);

void fragment() {
    if (!is_active) {
        COLOR = vec4(0.0);
    } else {
        vec2 uv = UV;   // 0,0 = top-left; 1,1 = bottom-right of the ColorRect.

        // ── scanlines ────────────────────────────────────────────────────────
        // Bands drifting downward — energy flowing into the console.
        float scan = sin((uv.y - TIME * 0.30) * 22.0) * 0.5 + 0.5;
        scan = pow(scan, 5.0) * 0.40;

        // ── core glow ─────────────────────────────────────────────────────────
        // Soft radial brightest-at-centre disc.
        float core = 1.0 - smoothstep(0.0, 0.52, length(uv - 0.5));
        core = pow(core, 2.5) * 0.55;

        // ── border ring ──────────────────────────────────────────────────────
        // Full brightness at tile edges, dark toward centre — FTL "console" feel.
        vec2  inner  = smoothstep(0.0, 0.12, uv) * (1.0 - smoothstep(0.88, 1.0, uv));
        float border = (1.0 - min(inner.x, inner.y)) * 0.75;

        // ── composite ────────────────────────────────────────────────────────
        float alpha = clamp(scan + core + border, 0.0, 1.0) * intensity;
        COLOR = vec4(glow_color.rgb, alpha);
    }
}
