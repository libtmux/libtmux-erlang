import { readFileSync } from 'node:fs';
const compiled = new Map();
for (const line of readFileSync(0, 'utf8').split('\n').filter((s) => s.length > 0)) {
  const tab = line.indexOf('\t');
  const pattern = line.slice(0, tab);
  const subject = Buffer.from(line.slice(tab + 1), 'hex');
  if (subject.some((b) => b > 127)) {
    console.log('unsupported_regex_subject');
    continue;
  }
  if (!compiled.has(pattern)) compiled.set(pattern, new RegExp(pattern));
  console.log(compiled.get(pattern).test(subject.toString('ascii')));
}
