// make release writes the version into the files that carry it, then commits them before tagging.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildNumber } from './release.mjs';

export const VERSION_FILES = ['mob-ios.xcodeproj/project.pbxproj'];

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
