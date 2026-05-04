// room_highlight.gdshader
// Apply to a ColorRect sized and positioned over a single tile.
// UV space is 0-1 across the rect, so all math stays tile-local —
// no SCREEN_UV needed and no alignment drift at any resolution.
shader_type canvas_item;
render_mode blend_add;      // additive: glows *over* the tile without hiding it

uniform float intensity  : hint_range(0.0, 1.0) = 1.0;
uniform vec4  glow_color : source_color = vec4(0.2, 1.0, 0.3, 1.0);

void fragment() {
    vec2 uv = UV;   // 0,0 = top-left corner of the ColorRect; 1,1 = bottom-right

    // ── scanlines ────────────────────────────────────────────────────────────
    // Horizontal bands that scroll upward over time.
    float scan = sin((uv.y - TIME * 0.45) * 20.0) * 0.5 + 0.5;
    scan = pow(scan, 4.0) * 0.35;

    // ── border glow ──────────────────────────────────────────────────────────
    // Full brightness at the tile edges, dark toward the centre.
    vec2  inner  = smoothstep(0.0, 0.13, uv) * (1.0 - smoothstep(0.87, 1.0, uv));
    float border = 1.0 - min(inner.x, inner.y);    // 1 at edges, 0 in centre

    // ── composite ────────────────────────────────────────────────────────────
    float alpha = clamp(scan + border * 0.75, 0.0, 1.0) * intensity;
    COLOR = vec4(glow_color.rgb, alpha);
}
