export type AnimatedIconName = 'account' | 'services' | 'newChat' | 'sideChat' | 'preferences' | 'tools' | 'appearance' |
  'data' | 'help' | 'history' | 'search' | 'folder' | 'settings' | 'browser' | 'document' | 'branch' | 'plus' |
  'announcement' | 'code' | 'preview' | 'dockRight';

function pulse(progress: number, from: number, to: number): number {
  if (progress <= from || progress >= to) { return 0; }
  const wave = Math.sin(Math.PI * (progress - from) / (to - from));
  return wave * wave;
}

function ellipse(x: number, y: number, rx: number, ry: number = rx): string {
  return `M${x - rx} ${y} a${rx} ${ry} 0 1 0 ${2 * rx} 0 a${rx} ${ry} 0 1 0 ${-2 * rx} 0 Z`;
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

export function iconPath(name: AnimatedIconName, progress: number, strength: number): string {
  const anticipation = pulse(progress, 0, 0.52) * strength;
  const release = pulse(progress, 0.26, 1) * strength;
  switch (name) {
    case 'appearance':
      return `M12 3.5 C6.7 3.5 3 7.5 3 12.2 C3 17 7.2 20.5 12 20.5 H13.7 C15.6 20.5 16.3 19 15.1 17.7
        C13.3 15.7 14.8 14.3 17.2 14.3 H18 C20 14.3 21 12.9 21 11.2 C21 6.8 17.3 3.5 12 3.5 Z
        M7.1 11 h0.01 M10.2 ${7.6 - 0.8 * release} h0.01 M14.3 7.6 h0.01 M17.3 10.4 h0.01`;
    case 'account':
      return `M4 20 V18.7 C4 15.6 7.6 ${15.1 - release} 12 ${15.1 - release} C16.4 ${15.1 - release} 20 15.6 20 18.7 V20
        ${ellipse(12, 8.1 + anticipation - 1.5 * release, 3.45)}`;
    case 'services':
      return `M5 5 H19 Q21 5 21 7 V17 Q21 19 19 19 H5 Q3 19 3 17 V7 Q3 5 5 5 Z M3 12 H21
        M7 8.5 h0.01 M7 15.5 h0.01 M11 8.5 H${17 + 1.5 * release} M11 15.5 H17`;
    case 'newChat': {
      const arm = 3.1 + 0.9 * release - 0.4 * anticipation;
      return `M6 4.5 H18 Q21 4.5 21 7.5 V14 Q21 17 18 17 H10.5 L3 21 V7.5 Q3 4.5 6 4.5 Z
        M${12 - arm} 10.75 H${12 + arm} M12 ${10.75 - arm} V${10.75 + arm}`;
    }
    case 'sideChat':
      return `M5.5 5 H13.4 Q16 5 16 7.6 V12 Q16 14.5 13.4 14.5 H8.5 L3 18 V7.6 Q3 5 5.5 5 Z
        M${18.8 + release} 9 Q21 9.5 21 11.5 V20 L17 17.5 H12.5`;
    case 'preferences':
      return `M5 5 H19 Q21 5 21 7 V17 Q21 19 19 19 H5 Q3 19 3 17 V7 Q3 5 5 5 Z
        ${ellipse(8.5, 10, 1.65)} M5.8 15.5 Q8.5 12.3 11.2 15.5 M14 9 H${18 + release} M14 14.5 H18`;
    case 'dockRight': {
      const tip = 17.5 + release - 0.5 * anticipation;
      return `M5 4.5 H19 Q21 4.5 21 6.5 V17.5 Q21 19.5 19 19.5 H5 Q3 19.5 3 17.5 V6.5 Q3 4.5 5 4.5 Z
        M14 4.5 V8 M14 16 V19.5 M6 12 H${tip} M${tip - 3} 9 L${tip} 12 L${tip - 3} 15`;
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
    case 'code': {
      const spread = 1.55 * release - 0.6 * anticipation;
      return `M${7.45 - spread} 7.75 L${3.1 - spread} 12 L${7.45 - spread} 16.25
        M${16.55 + spread} 7.75 L${20.9 + spread} 12 L${16.55 + spread} 16.25 M13.85 5.9 L10.15 18.1`;
    }
    case 'preview': {
      const open = 1.2 * release - 0.85 * anticipation;
      return `M2.5 12 C7.2 ${4.1 - open} 16.8 ${4.1 - open} 21.5 12
        C16.8 ${19.9 + open} 7.2 ${19.9 + open} 2.5 12 Z
        ${ellipse(12, 12, 2.55, 2.55 + 0.35 * open)}`;
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
  }
}
