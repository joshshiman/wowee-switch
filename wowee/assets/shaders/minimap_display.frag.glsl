#version 450

layout(set = 0, binding = 0) uniform sampler2D uComposite;

layout(push_constant) uniform Push {
    vec4 rect;
    vec2 playerUV;
    float rotation;
    float arrowRotation;
    float zoomRadius;
    int squareShape;
    float opacity;
    float showArrow;
} push;

layout(location = 0) in vec2 TexCoord;

layout(location = 0) out vec4 outColor;

float cross2d(vec2 a, vec2 b) {
    return a.x * b.y - a.y * b.x;
}

bool pointInTriangle(vec2 p, vec2 a, vec2 b, vec2 c) {
    float d1 = cross2d(b - a, p - a);
    float d2 = cross2d(c - b, p - b);
    float d3 = cross2d(a - c, p - c);
    bool hasNeg = (d1 < 0.0) || (d2 < 0.0) || (d3 < 0.0);
    bool hasPos = (d1 > 0.0) || (d2 > 0.0) || (d3 > 0.0);
    return !(hasNeg && hasPos);
}

void main() {
    vec2 center = TexCoord - 0.5;
    float dist = length(center);

    if (push.squareShape == 0) {
        if (dist > 0.5) discard;
    }

    float cs = cos(push.rotation);
    float sn = sin(push.rotation);
    vec2 mapCenter = vec2(-center.x, center.y);
    vec2 rotated = vec2(mapCenter.x * cs - mapCenter.y * sn, mapCenter.x * sn + mapCenter.y * cs);
    // The composite's u grows east and its v grows south: compositePass gives
    // gridOffset.x to dc (tileY, which rises eastward) and gridOffset.y to dr
    // (tileX, which falls as renderY/north rises), so v = 0 is the composite's top
    // row. TexCoord.y = 0 is the top of this quad, so a north-up map takes u from
    // screen right - mapCenter above has already negated rotated.x into +center.x -
    // and v from screen up, which is rotated.y. zoomRadius is already in composite
    // UV (viewRadius / 3 tiles); the gain below is over it and must stay 1.0.
    vec2 mapUV = push.playerUV + vec2(-rotated.x, rotated.y) * push.zoomRadius * 1.0;

    vec4 mapColor = texture(uComposite, mapUV);

    // Single player direction indicator (center arrow) rendered in-shader.
    vec2 local = center; // [-0.5, 0.5] around minimap center
    float ac = cos(push.arrowRotation);
    float as = sin(push.arrowRotation);
    // TexCoord Y grows downward on screen; use negative Y so 0-angle points North (up).
    vec2 tip   = vec2(0.0, -0.09);
    vec2 left  = vec2(-0.045, 0.02);
    vec2 right = vec2( 0.045, 0.02);
    mat2 rot = mat2(ac, -as, as, ac);
    tip = rot * tip;
    left = rot * left;
    right = rot * right;
    if (push.showArrow > 0.5 && pointInTriangle(local, tip, left, right)) {
        mapColor.rgb = vec3(1.0, 0.86, 0.05);
    }
    float centerDot = smoothstep(0.016, 0.0, length(local));
    mapColor.rgb = mix(mapColor.rgb, vec3(1.0), centerDot * 0.95);

    // Dark border ring
    float border = smoothstep(0.48, 0.5, dist);
    if (push.squareShape == 0) {
        mapColor.rgb *= 1.0 - border * 0.7;
    }

    outColor = vec4(mapColor.rgb, mapColor.a * push.opacity);
}
