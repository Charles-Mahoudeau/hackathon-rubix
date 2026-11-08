// Procedural pixel space background. Algorithm by Deep-Fold (PixelSpace / Space Background Generator, MIT,
// https://github.com/Deep-Fold/PixelSpace: Nebulae.shader and StarStuff.shader), ported to the AYLO shader dialect.
// Differences from the original: the colour-scheme texture is replaced by a 4-step ramp of palette uniforms, and the
// output is only ever one of the uniform colours (selected, never blended), so nothing off-palette reaches the screen.
// Draw it on a sprite whose source is the whole of assets/textures/white.png: UV runs 0..1 over the layer.

uniform float mode = 0.0;         // 0: nebula (clouds with a thin outline band). 1: dust and stars (transparent between).
uniform float seed = 1.0;         // Per layer: changes the pattern.
uniform float pixels = 360.0;     // Pixel rows of the layer (the lower, the chunkier). Columns are pixels * aspect: square pixels.
uniform float aspect = 1.0;       // Width / height of the covered area.
uniform float size = 6.0;         // Noise scale: how many clouds.
uniform int octaves = 4;
uniform vec2 drift = vec2(0.002, 0.0); // Noise scrolled per second. Different per layer gives the parallax.
uniform float starDensity = 0.012; // Share of pixels that are a star (mode 1).
uniform vec4 ramp0 = vec4(0.04, 0.05, 0.1, 1.0);  // Empty space,
uniform vec4 ramp1 = vec4(0.12, 0.16, 0.27, 1.0); // then the cloud from its thin edge...
uniform vec4 ramp2 = vec4(0.24, 0.36, 0.46, 1.0);
uniform vec4 ramp3 = vec4(0.62, 0.83, 0.9, 1.0);  // ... to its dense core.
uniform vec4 star1 = vec4(0.95, 0.92, 0.87, 1.0);
uniform vec4 star2 = vec4(0.85, 0.7, 0.44, 1.0);
uniform float twinkle = 0.3;      // Stars blink off now and then, this many times a second (0: steady).

float rand(vec2 coord) {
    return fract(sin(dot(coord, vec2(12.9898, 78.233))) * (15.5453 + seed));
}

float noise(vec2 coord) {
    vec2 i = floor(coord);
    vec2 f = fract(coord);
    float a = rand(i);
    float b = rand(i + vec2(1.0, 0.0));
    float c = rand(i + vec2(0.0, 1.0));
    float d = rand(i + vec2(1.0, 1.0));
    vec2 cubic = f * f * (3.0 - 2.0 * f);
    return mix(a, b, cubic.x) + (c - a) * cubic.y * (1.0 - cubic.x) + (d - b) * cubic.x * cubic.y;
}

float fbm(vec2 coord) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += noise(coord) * amplitude;
        coord *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// Round blobs that warp the cloud noise: gives the swirly, turbulent edges.
float circleNoise(vec2 uv) {
    float uvY = floor(uv.y);
    uv.x += uvY * 0.31;
    vec2 f = fract(uv);
    float h = rand(vec2(floor(uv.x), uvY));
    float m = length(f - 0.25 - (h * 0.5));
    float r = h * 0.25;
    return smoothstep(0.0, r, m * 0.75);
}

float cloud(vec2 uv) {
    float warp = 0.0;
    for (int i = 0; i < 2; i++) {
        warp += circleNoise(uv * 0.5 + float(i + 1) + vec2(-0.3, 0.0));
    }
    return fbm(uv + warp);
}

// The ramp step of a 0..1+ density: 0 empty, then 1 to 3.
vec3 rampColor(float level) {
    vec3 c = ramp0.rgb;
    c = mix(c, ramp1.rgb, step(1.0, level));
    c = mix(c, ramp2.rgb, step(3.0, level));
    c = mix(c, ramp3.rgb, step(5.0, level));
    return c;
}

void fragment() {
    vec2 grid = vec2(pixels * aspect, pixels);
    vec2 uv = floor(UV * grid) / grid;
    bool dith = mod(floor(UV.x * grid.x) + floor(UV.y * grid.y), 2.0) < 1.0; // checkerboard dither, as in the original
    vec2 square = vec2(aspect, 1.0); // noise space with square cells, so clouds are not stretched
    vec2 base = (uv * square + drift * TIME) * size;

    if (mode < 0.5) {
        float d = distance(uv * square, vec2(0.5) * square) * 0.4;
        float n = cloud(base);
        float n2 = fbm(base + vec2(1.0, 1.0));
        float density = n2 * n * n; // n2 * (n * n): dust inside the cloud
        if (dith) {
            density *= 0.95;
            d *= 0.98;
        }
        float a = step(n2, 0.1 + d);
        float a2 = step(n2, 0.115 + d);
        // The thin band between a and a2 is brighter: the outline of the cloud.
        float level = floor(density * mix(14.0, 35.0, a2 - a));
        COLOR = vec4(rampColor(level), 1.0);
    } else {
        float nAlpha = fbm(base * ceil(size * 0.5) / size + vec2(2.0, 2.0));
        float dust = cloud(base) * fbm(base * 0.2 - vec2(2.0, 2.0));
        if (dith) {
            dust *= 0.95;
        }
        float aDust = step(nAlpha, dust * 1.8);
        float level = floor(pow(dust, 3.2) * 56.0);
        vec3 color = rampColor(max(level, 1.0));
        // Stars: a hash per pixel of the grid, fixed on screen (they do not drift with the dust).
        float h = fract(sin(dot(floor(UV * grid) + vec2(seed), vec2(127.1, 311.7))) * 43758.5453);
        float isStar = step(1.0 - starDensity, h);
        isStar *= 1.0 - step(0.85, sin(TIME * twinkle * 6.2832 + h * 4000.0) * 0.5 + 0.5) * step(0.0001, twinkle);
        vec3 starColor = mix(star2.rgb, star1.rgb, step(0.5, fract(h * 97.0)));
        color = mix(color, starColor, isStar);
        COLOR = vec4(color, max(aDust, isStar));
    }
}
