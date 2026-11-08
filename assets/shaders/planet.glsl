// Procedural pixel planet. Algorithm by Deep-Fold (Pixel Planet Generator, MIT, https://deep-fold.itch.io/pixel-planet-generator),
// following the "land masses" planet as ported in selimanac/defold-pixel-planets. Rewritten for the AYLO shader dialect:
// one fragment pass draws water, land and clouds, with every colour taken from the material (the game's 8-colour palette).
// Draw it on a sprite whose source is the whole of assets/textures/white.png: UV runs 0..1 over the planet's square.

uniform float seed = 1.0;         // Per planet: changes the continents and clouds.
uniform float pixels = 64.0;      // Pixel grid of the planet (the lower, the chunkier).
uniform float size = 5.0;         // Noise scale: how many continents. Whole number.
uniform float timeSpeed = 0.02;   // Rotation: noise scrolled per second. Slow.
uniform float tilt = 0.0;         // Rotation of the sphere, in radians.
uniform float phase = 0.0;        // Starting point of the rotation (seconds), so planets do not turn in step.
uniform float waterLevel = 0.45;  // Below this noise value: water. 0 gives a planet that is all land.
uniform float cloudCover = 0.5;   // Cloud threshold. 1 or more: no clouds.
uniform int octaves = 3;
uniform float rimWidth = 0.0;     // Width of the outline ring, as a fraction of the disc. 0: no ring.
uniform vec4 rim1 = vec4(1.0, 1.0, 1.0, 1.0);    // Ring on the lit side,
uniform vec4 rim2 = vec4(0.4, 0.4, 0.5, 1.0);    // ring on the shadow side.
uniform vec2 lightOrigin = vec2(0.3, 0.3);
uniform vec2 lightBorders = vec2(0.4, 0.6);
uniform vec4 land1 = vec4(0.8, 0.8, 0.5, 1.0);   // Lit land, to...
uniform vec4 land2 = vec4(0.5, 0.7, 0.3, 1.0);
uniform vec4 land3 = vec4(0.3, 0.5, 0.3, 1.0);
uniform vec4 land4 = vec4(0.2, 0.3, 0.3, 1.0);   // ... land in shadow.
uniform vec4 water1 = vec4(0.3, 0.5, 0.9, 1.0);  // Lit water,
uniform vec4 water2 = vec4(0.1, 0.2, 0.5, 1.0);  // water in shadow.
uniform vec4 cloud1 = vec4(1.0, 1.0, 1.0, 1.0);  // Lit cloud,
uniform vec4 cloud2 = vec4(0.7, 0.7, 0.8, 1.0);  // cloud in shadow.

float rand(vec2 coord, float tile, float s) {
    // Tiled in x (twice the width: the far side of the planet) so the scroll loops without a seam.
    coord = mod(coord, vec2(2.0, 1.0) * floor(tile + 0.5));
    return fract(sin(dot(coord, vec2(12.9898, 78.233))) * 43758.5453 * s);
}

float noise(vec2 coord, float tile, float s) {
    vec2 i = floor(coord);
    vec2 f = fract(coord);
    float a = rand(i, tile, s);
    float b = rand(i + vec2(1.0, 0.0), tile, s);
    float c = rand(i + vec2(0.0, 1.0), tile, s);
    float d = rand(i + vec2(1.0, 1.0), tile, s);
    vec2 cubic = f * f * (3.0 - 2.0 * f);
    return mix(a, b, cubic.x) + (c - a) * cubic.y * (1.0 - cubic.x) + (d - b) * cubic.x * cubic.y;
}

float fbm(vec2 coord, float tile, float s) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += noise(coord, tile, s) * amplitude;
        coord *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

vec2 spherify(vec2 uv) {
    vec2 centered = uv * 2.0 - 1.0;
    float z = sqrt(max(1.0 - dot(centered, centered), 0.0));
    return (centered / (z + 1.0)) * 0.5 + 0.5;
}

vec2 rotate(vec2 coord, float angle) {
    coord -= 0.5;
    coord = vec2(coord.x * cos(angle) + coord.y * sin(angle), -coord.x * sin(angle) + coord.y * cos(angle));
    return coord + 0.5;
}

// Land and water: three shifted samples of the noise give the bands of shade, lit from lightOrigin.
vec3 ground(vec2 base, float dLight, float tile, float s) {
    float f1 = fbm(base, tile, s);
    float f2 = fbm(base - lightOrigin * f1, tile, s);
    float f3 = fbm(base - lightOrigin * 1.5 * f1, tile, s);
    float f4 = fbm(base - lightOrigin * 2.0 * f1, tile, s);
    if (dLight < lightBorders.x) {
        f4 *= 0.9;
    }
    if (dLight > lightBorders.x) {
        f2 *= 1.05;
        f3 *= 1.05;
        f4 *= 1.05;
    }
    if (dLight > lightBorders.y) {
        f2 *= 1.3;
        f3 *= 1.4;
        f4 *= 1.8;
    }
    float shade = pow(dLight, 2.0) * 0.1;
    vec3 land = land4.rgb;
    land = mix(land, land3.rgb, float(f4 + shade < f1));
    land = mix(land, land2.rgb, float(f3 + shade < f1));
    land = mix(land, land1.rgb, float(f2 + shade < f1));
    vec3 water = mix(water2.rgb, water1.rgb, float(dLight < lightBorders.y));
    return mix(water, land, step(waterLevel, f1));
}

void fragment() {
    vec2 uv = floor(UV * pixels) / pixels;
    float disc = step(distance(uv, vec2(0.5)), 0.5);
    float dLight = distance(uv, lightOrigin);
    float edge = distance(uv, vec2(0.5));
    uv = spherify(rotate(uv, tilt));
    float tile = size;
    float t = (TIME + phase) * timeSpeed;
    vec2 base = uv * size + vec2(t * size, 0.0);

    vec3 color = ground(base, dLight, tile, seed);

    // Clouds: a second noise, scrolled a little faster, over the ground.
    float ctile = floor(size * 2.0 + 0.5);
    vec2 cbase = uv * (size * 2.0) + vec2(t * size * 2.0 * 1.5, 0.0);
    float c1 = fbm(cbase, ctile, seed + 3.7);
    float c2 = fbm(cbase - lightOrigin * c1, ctile, seed + 3.7);
    float cloudMask = step(cloudCover, c1);
    vec3 cloud = mix(cloud1.rgb, cloud2.rgb, float(c2 < c1 - 0.04 + dLight * 0.2));
    color = mix(color, cloud, cloudMask);

    // The outline keeps the disc readable where the shaded side is as dark as the space behind it.
    vec3 ring = mix(rim2.rgb, rim1.rgb, float(dLight < lightBorders.y));
    color = mix(color, ring, step(0.5 - rimWidth, edge) * step(0.0001, rimWidth));

    COLOR = vec4(color * disc, disc);
}
