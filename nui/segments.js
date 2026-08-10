/**
 * 7-segment display: segments A-G
 * Layout:     A
 *           F   B
 *             G
 *           E   C
 *             D
 */
const SEGMENTS = {
    A: { x: 2, y: 0, w: 18, h: 3 },
    B: { x: 19, y: 3, w: 3, h: 13 },
    C: { x: 19, y: 19, w: 3, h: 13 },
    D: { x: 2, y: 33, w: 18, h: 3 },
    E: { x: 0, y: 19, w: 3, h: 13 },
    F: { x: 0, y: 3, w: 3, h: 13 },
    G: { x: 2, y: 16, w: 18, h: 3 },
};

const VIEWBOX = '0 0 22 36';

const DIGIT_MAP = {
    '0': ['A', 'B', 'C', 'D', 'E', 'F'],
    '1': ['B', 'C'],
    '2': ['A', 'B', 'D', 'E', 'G'],
    '3': ['A', 'B', 'C', 'D', 'G'],
    '4': ['B', 'C', 'F', 'G'],
    '5': ['A', 'C', 'D', 'F', 'G'],
    '6': ['A', 'C', 'D', 'E', 'F', 'G'],
    '7': ['A', 'B', 'C'],
    '8': ['A', 'B', 'C', 'D', 'E', 'F', 'G'],
    '9': ['A', 'B', 'C', 'D', 'F', 'G'],
    ' ': [],
};

function segmentToPath(seg) {
    const { x, y, w, h } = seg;
    return `M ${x} ${y} h ${w} v ${h} h ${-w} Z`;
}

function createSegmentPath(segId) {
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', segmentToPath(SEGMENTS[segId]));
    path.setAttribute('data-segment', segId);
    return path;
}

function createDigitSvg(className = '') {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', VIEWBOX);
    svg.setAttribute('class', `digit-svg ${className}`);
    svg.setAttribute('preserveAspectRatio', 'none');

    const ghostLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    ghostLayer.setAttribute('class', 'digit-ghost');
    const liveLayer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    liveLayer.setAttribute('class', 'digit-live');

    'ABCDEFG'.split('').forEach(segId => {
        const ghostPath = createSegmentPath(segId);
        ghostPath.setAttribute('class', 'segment-ghost');
        ghostLayer.appendChild(ghostPath);

        const livePath = createSegmentPath(segId);
        livePath.setAttribute('class', 'segment-live');
        liveLayer.appendChild(livePath);
    });

    svg.appendChild(ghostLayer);
    svg.appendChild(liveLayer);
    return svg;
}

function setDigit(svg, char) {
    const active = DIGIT_MAP[char] || DIGIT_MAP[' '];
    const liveSegments = svg.querySelectorAll('.segment-live');
    liveSegments.forEach(path => {
        const segId = path.getAttribute('data-segment');
        path.classList.toggle('on', active.includes(segId));
    });
}

function createDigitDisplay(count = 3, containerClass = '') {
    const wrap = document.createElement('div');
    wrap.className = `digit-display ${containerClass}`;
    for (let i = 0; i < count; i++) {
        const svg = createDigitSvg();
        wrap.appendChild(svg);
    }
    return wrap;
}

function updateDigitDisplay(wrap, str) {
    const padded = String(str).padStart(3).slice(-3);
    const chars = padded.split('');
    const svgs = wrap.querySelectorAll('.digit-svg');
    chars.forEach((c, i) => {
        if (svgs[i]) setDigit(svgs[i], c === ' ' || c === '' ? ' ' : c);
    });
}
