export interface ThirdPartyLicense {
  id: string;
  name: string;
  license: string;
  copyright: string;
  resource: string;
}

// Keep notices verbatim from the distributed components; development-only tools are not shipped.
export const THIRD_PARTY_LICENSES: ThirdPartyLicense[] = [
  {
    id: 'reactbits', name: 'ReactBits · Shiny Text / Spotlight Card / Animated Content', license: 'MIT + Commons Clause',
    copyright: 'Copyright (c) 2026 David Haz', resource: 'licenses/reactbits.txt'
  },
  {
    id: 'katex', name: 'KaTeX · 0.19.0', license: 'MIT',
    copyright: 'Copyright (c) 2013-2020 Khan Academy and other contributors', resource: 'math/LICENSE.txt'
  },
  {
    id: 'quickjs', name: 'QuickJS · 2026-06-04', license: 'MIT',
    copyright: 'Copyright (c) 2017-2021 Fabrice Bellard\nCopyright (c) 2017-2021 Charlie Gordon',
    resource: 'licenses/quickjs.txt'
  },
  {
    id: 'bencho', name: 'Bencho Liquid Toggle', license: 'MIT',
    copyright: 'Copyright (c) 2026 Lorenzo Cabra', resource: 'licenses/bencho.txt'
  },
  {
    id: 'three', name: 'Three.js / OrbitControls · 0.186.1', license: 'MIT',
    copyright: 'Copyright © 2010-2026 three.js authors', resource: 'interactive-web/THREE-LICENSE.txt'
  },
  {
    id: 'office-bundle', name: 'fflate / xmldom / PptxGenJS slide template', license: 'MIT',
    copyright: 'Arjun Barrett, xmldom contributors, and Brent Ely', resource: 'licenses/office-bundle.txt'
  },
  {
    id: 'huawei-samples', name: 'Huawei Ability samples', license: 'Apache-2.0',
    copyright: 'Copyright (c) 2026 Huawei Device Co., Ltd.', resource: 'licenses/huawei-samples.txt'
  }
];
