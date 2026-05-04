// room_border.gdshader
// Full-room border glow overlay. Attach to a ColorRect sized to the room.
// render_mode blend_add: glows on top of tiles without obscuring them.
//
// Driven from GDScript (room_base.gd):
//   mat.set_shader_parameter("is_active",   true/false)   // on/off
//   mat.set_shader_parameter("border_color", Color(...))  // yellow for hover, green for movement
//   mat.set_shader_parameter("intensity",    0.0..1.0)    // tweened for pulsing
shader_type canvas_item;
render_mode blend_mix;

uniform bool  is_active                               = false;
uniform float intensity        : hint_range(0.0, 1.0) = 1.0;
uniform vec4  border_color     : source_color          = vec4(1.0, 1.0, 0.0, 1.0);
uniform float border_thickness : hint_range(0.01, 0.4) = 0.07;

void fragment() {
    if (!is_active) {
        COLOR = vec4(0.0);
    } else {
        vec2 uv = UV;

        // inner = 1.0 in the center, 0.0 at the edges within border_thickness
        vec2  inner  = smoothstep(0.0, border_thickness, uv)
                     * (1.0 - smoothstep(1.0 - border_thickness, 1.0, uv));
        // border = 1.0 at edges, 0.0 in the interior
        float border = 1.0 - min(inner.x, inner.y);

        // Sharpen the falloff so the glow is crisp at the edge
        border = pow(border, 1.8);

        float alpha = clamp(border * intensity, 0.0, 1.0);
        COLOR = vec4(border_color.rgb, alpha);
    }
}
