export type AnimatedIconName = 'account' | 'cloud' | 'compose' | 'tools' | 'mountain' | 'data' | 'help' |
  'history' | 'search' | 'folder' | 'settings' | 'browser' | 'document' | 'branch' | 'plus' | 'announcement' | 'tinybot';

function pulse(progress: number, from: number, to: number): number {
  if (progress <= from || progress >= to) { return 0; }
  const wave = Math.sin(Math.PI * (progress - from) / (to - from));
  return wave * wave;
}

function ellipse(x: number, y: number, rx: number, ry: number = rx): string {
  return `M${x - rx} ${y} a${rx} ${ry} 0 1 0 ${2 * rx} 0 a${rx} ${ry} 0 1 0 ${-2 * rx} 0 Z`;
}

function mountains(progress: number, strength: number): string {
  const front = 11.4 + strength * (2.4 * pulse(progress, 0, 0.44) - 2.1 * pulse(progress, 0.34, 1));
  const rear = 12.4 + strength * (1.8 * pulse(progress, 0.06, 0.49) - 1.2 * pulse(progress, 0.44, 1));
  const sun = 8.65 + strength * (1.2 * pulse(progress, 0, 0.43) - 1.6 * pulse(progress, 0.32, 1));
  const join = front + 0.45 + (16.4 - front - 0.45) * 0.55;
  return `M5.5 4.5 H18.5 Q21 4.5 21 7 V17 Q21 19.5 18.5 19.5 H5.5 Q3 19.5 3 17 V7 Q3 4.5 5.5 4.5 Z
    M3.1 17.1 L8.45 ${front + 0.45} Q9 ${front - 0.1} 9.55 ${front + 0.45} L14.1 16.4
    M12.05 ${join} L14.55 ${rear + 0.45} Q15.1 ${rear - 0.1} 15.65 ${rear + 0.45} L20.9 17.05
    ${ellipse(16.2, sun, 0.8)}`;
}

function gear(turn: number): string {
  let path = '';
  for (let tooth = 0; tooth < 8; tooth++) {
    for (let edge = 0; edge < 4; edge++) {
      const angle = (tooth + (edge + 0.5) / 4) * Math.PI / 4 + turn;
      const radius = edge === 1 || edge === 2 ? 9.1 : 7.3;
      path += `${tooth === 0 && edge === 0 ? 'M' : ' L'}${12 + radius * Math.cos(angle)} ${12 + radius * Math.sin(angle)}`;
    }
  }
  return path + ' Z ' + ellipse(12, 12, 3);
}

export function tinybotSpark(progress: number, strength: number): string {
  const lift = pulse(progress, 0.28, 1) * strength;
  return ellipse(20.3 + 0.8 * lift, 4 - 1.4 * lift, 1.4 + 0.25 * lift);
}

export function iconPath(name: AnimatedIconName, progress: number, strength: number): string {
  const anticipation = pulse(progress, 0, 0.52) * strength;
  const release = pulse(progress, 0.26, 1) * strength;
  switch (name) {
    case 'mountain': return mountains(progress, strength);
    case 'account':
      return `M4 20 V18.7 C4 15.6 7.6 ${15.1 - release} 12 ${15.1 - release} C16.4 ${15.1 - release} 20 15.6 20 18.7 V20
        ${ellipse(12, 8.1 + anticipation - 1.5 * release, 3.45)}`;
    case 'cloud': {
      const arrow = 11.4 + anticipation - 1.65 * release;
      return `M7 17.8 H6.3 A4.3 4.3 0 1 1 7.8 9.5 A5.3 5.3 0 0 1 18 10 A3.9 3.9 0 0 1 17.7 17.8 H16.9
        M9.1 ${arrow + 2.8} L12 ${arrow} L14.9 ${arrow + 2.8} M12 ${arrow} V19.7`;
    }
    case 'compose': {
      const x = 9.1 + 1.45 * release;
      const y = 15.4 + 0.7 * anticipation - 1.25 * release;
      return `M12.4 4.2 H6.2 Q4 4.2 4 6.4 V17.8 Q4 20 6.2 20 H17.5 Q19.7 20 19.7 17.8 V12.4
        M${x} ${y} l0.85 -3.85 6.1 -6.1 q0.8 -0.8 1.6 0 l1.15 1.15 q0.8 0.8 0 1.6 l-6.1 6.1 Z
        M${x + 5.6} ${y - 8.25} l2.65 2.65`;
    }
    case 'tools': {
      const x = 8.2 - 0.95 * release;
      const y = 14.05 + 1.2 * release;
      return `M14.1 4.05 a4 4 0 0 0 -5.2 4.9 L4.65 13.2 a2 2 0 0 0 2.8 2.8 l4.3 -4.25 a4 4 0 0 0 4.9 -5.15 l-2.5 2.45 -2.5 -2.5 Z
        M${x + 3.1} ${y - 1.3} l5.7 5.7 M${x + 6.6} ${y + 3.4} l2.05 -2.05 3.1 3.1 -2.05 2.05 Z`;
    }
    case 'data': {
      const middle = 11.8 - 1.55 * release;
      const bottom = 16.2 + 1.45 * anticipation - 0.7 * release;
      return `M5 7.5 V17 Q5 20.1 12 20.1 Q19 20.1 19 17 V7.5 ${ellipse(12, 7.5, 7, 2.7)}
        M5 ${middle} Q5 ${middle + 3.25} 12 ${middle + 3.25} Q19 ${middle + 3.25} 19 ${middle}
        M5 ${bottom} Q5 ${bottom + 2.15} 12 ${bottom + 2.15} Q19 ${bottom + 2.15} 19 ${bottom}`;
    }
    case 'help': {
      const y = 9.1 + 0.7 * anticipation - 1.2 * release;
      return `${ellipse(12, 12, 8.65)} M9.3 ${y} c0.25 -2.7 5.5 -2.75 5.5 0
        c0 1.9 -2.8 2 -2.8 4.1 M12 ${16.9 - 1.65 * release} h0.02`;
    }
    case 'history':
      return `M5 4.5 H19 Q21 4.5 21 6.5 V17.5 Q21 19.5 19 19.5 H5 Q3 19.5 3 17.5 V6.5 Q3 4.5 5 4.5 Z
        M8 4.5 V19.5 M11.5 8.7 H${17.3 - 2.4 * anticipation} M11.5 12 H${17.3 - 2.4 * release}
        M11.5 15.3 H${15.7 + 1.9 * release}`;
    case 'search': {
      const x = 10.2 + 1.3 * release;
      const y = 10.15 - 1.55 * release;
      const radius = 5.75 - 0.55 * anticipation;
      return `${ellipse(x, y, radius)} M${x + radius * 0.707} ${y + radius * 0.707} L20 20
        M${x - 2.9} ${y - 0.35} Q${x - 2.6} ${y - 2.65} ${x - 0.2} ${y - 2.9}`;
    }
    case 'folder': {
      const top = 10.25 - 2.7 * release + 0.65 * anticipation;
      return `M3.5 16.6 V6.6 Q3.5 4.8 5.3 4.8 H9.1 L11.3 7 H18 Q19.8 7 19.8 8.8 V${top + 0.9}
        M3.5 16.6 L5.15 ${top + 1.4} Q5.5 ${top} 7.05 ${top} H20 Q21.35 ${top} 21.15 ${top + 1.5}
        L19.95 17.65 Q19.7 19.2 18.05 19.2 H5.2 Q3.05 19.2 3.5 16.6 Z`;
    }
    case 'settings': return gear(0.26 * release - 0.12 * anticipation);
    case 'browser': {
      const tilt = 2.8 * release - 1.2 * anticipation;
      return `${ellipse(12, 12, 8.75)} M12 3.25 C${5.75 + tilt} 6 ${5.75 - tilt} 18 12 20.75
        C${18.25 + tilt} 18 ${18.25 - tilt} 6 12 3.25 Z M3.25 12 Q12 ${12 + 2.1 * release} 20.75 12`;
    }
    case 'document':
      return `M6 3.8 H14.4 L18.3 7.7 V18.6 Q18.3 20.2 16.7 20.2 H7.5 Q5.9 20.2 5.9 18.6 V5.5 Q5.9 3.8 7.5 3.8
        M14.4 3.8 V7.7 H18.3 M9 11.4 H${15.1 - 2.2 * anticipation} M9 14.1 H${15.1 - 2.2 * release} M9 16.8 H${13.3 + 1.4 * release}`;
    case 'branch': {
      const x = 17.4 + 2.2 * release - anticipation;
      const y = 6.1 - 1.35 * release;
      return `M6 8.5 V15.6 M6 14.5 H10 Q${x} 14.5 ${x} ${y + 2.3}
        ${ellipse(6, 6.1, 2.25)} ${ellipse(6, 18, 2.25)} ${ellipse(x, y, 2.25)}`;
    }
    case 'plus':
      return `M${5.25 - 1.35 * release} 12 H${18.75 + 1.35 * release}
        M12 ${5.25 + 2 * anticipation - release} V${18.75 - 2 * anticipation + release}`;
    case 'announcement': {
      const wave = 1.65 * release - 0.65 * anticipation;
      return `M3.4 9.15 H7.2 L16 4.8 V18.1 L7.2 13.75 H3.4 Z M7.2 9.15 V13.75 L9.2 19.55 H6.65 L4.8 13.75
        M${18.55 + wave} 8.15 L${20.15 + wave} 6.85 M${19 + wave} 11.45 H${21 + wave}
        M${18.55 + wave} 14.75 L${20.15 + wave} 16.05`;
    }
    case 'tinybot': return ellipse(8.85, 10.2, 1.85, 1.85 - 1.58 * anticipation);
  }
}
