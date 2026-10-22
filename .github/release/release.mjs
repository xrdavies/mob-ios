// Version rules shared by make release (tag.mjs) and its tests.
export function version(value) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value ?? '')) throw Error('Expected a stable MAJOR.MINOR.PATCH version');
  return value;
}

// Build number (CFBundleVersion), the same formula as Android's versionCode: 1.2.3 → 1002003.
export function buildNumber(value) {
  const [major, minor, patch] = version(value).split('.').map(Number);
  if (minor > 999 || patch > 999) throw Error('Minor and patch must stay below 1000');
  return major * 1_000_000 + minor * 1_000 + patch;
}

export function checkPromotion(current, next) {
  const a = version(current.version).split('.').map(BigInt);
  const b = version(next.version).split('.').map(BigInt);
  for (let i = 0; i < 3; i++) {
    if (b[i] > a[i]) return;
    if (b[i] < a[i]) throw Error(`Refusing to move backwards from ${current.version} to ${next.version}`);
  }
}
