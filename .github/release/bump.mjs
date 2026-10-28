// make release writes the version into the files that carry it, then commits them before tagging.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildNumber, version } from './release.mjs';

export const VERSION_FILES = ['mob-ios.xcodeproj/project.pbxproj'];

// The MARKETING_VERSION every build configuration agrees on (make archive BUILD= may override the
// build number, so it is not checked). read(file) returns a file's text; by default from root.
export function readVersion(root, read = file => readFileSync(join(root, file), 'utf8')) {
  const file = VERSION_FILES[0];
  const all = new Set([...read(file).matchAll(/MARKETING_VERSION = ([^;\n]+);/g)].map(m => m[1]));
  if (all.size !== 1) throw Error(`${file}: expected one MARKETING_VERSION in every build configuration, found ${[...all].join(', ') || 'none'}`);
  return version([...all][0]);
}

// Sets MARKETING_VERSION and CURRENT_PROJECT_VERSION in every build configuration; returns the
// files that changed.
export function bumpVersion(root, version) {
  const file = VERSION_FILES[0];
  const before = readFileSync(join(root, file), 'utf8');
  const marketing = /MARKETING_VERSION = [^;\n]+;/g, build = /CURRENT_PROJECT_VERSION = [^;\n]+;/g;
  if (!marketing.test(before) || !build.test(before)) throw Error(`${file}: no MARKETING_VERSION or CURRENT_PROJECT_VERSION`);
  const after = before.replace(marketing, `MARKETING_VERSION = ${version};`).replace(build, `CURRENT_PROJECT_VERSION = ${buildNumber(version)};`);
  if (after === before) return [];
  writeFileSync(join(root, file), after);
  return [file];
}

export const PARTS = ['major', 'minor', 'patch'];

// The next version after current for make release-major, -minor or -patch.
export function increment(current, part) {
  const i = PARTS.indexOf(part);
  if (i < 0) throw Error(`Expected one of ${PARTS.join(', ')}`);
  const n = version(current).split('.').map(Number);
  n[i]++;
  n.fill(0, i + 1);
  return n.join('.');
}

export function compareVersions(a, b) {
  const x = version(a).split('.').map(BigInt), y = version(b).split('.').map(BigInt);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}
