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
    id: 'huawei-samples', name: 'Huawei Ability samples', license: 'Apache-2.0',
    copyright: 'Copyright (c) 2026 Huawei Device Co., Ltd.', resource: 'licenses/huawei-samples.txt'
  }
];
