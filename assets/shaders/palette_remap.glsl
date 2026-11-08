// Palette remap (GR5-3): a greyscale or white sprite is recoloured onto a 4-step ramp of the game's 8-colour theme, so one
// sprite serves every corporation. Only the ramp (a material value) differs per corporation, never the art.
// Output is always one of the four ramp colours: the steps are hard thresholds, nothing is blended outside the palette.

uniform vec4 ramp0 = vec4(0.0, 0.0, 0.0, 1.0);   // Darkest greys (bg).
uniform vec4 ramp1 = vec4(0.1, 0.1, 0.1, 1.0);   // Dark greys (panel).
uniform vec4 ramp2 = vec4(0.0, 0.9, 1.0, 1.0);   // Mid to light greys: the corporation's neon.
uniform vec4 ramp3 = vec4(1.0, 1.0, 1.0, 1.0);   // Near white (text).
uniform vec3 steps = vec3(0.25, 0.5, 0.85);      // Luminance thresholds between the four colours.

void fragment() {
    float a = COLOR.a;
    float l = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114)) / max(a, 0.0001);
    vec3 c = ramp0.rgb;
    c = mix(c, ramp1.rgb, step(steps.x, l));
    c = mix(c, ramp2.rgb, step(steps.y, l));
    c = mix(c, ramp3.rgb, step(steps.z, l));
    COLOR = vec4(c * a, a);
}
