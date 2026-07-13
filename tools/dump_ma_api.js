'use strict';
// Dump MobileActivation / DeviceIdentity APIs from identityservicesd (already linked).
function listClasses(re) {
  const rx = new RegExp(re, 'i');
  const out = [];
  for (const name of Object.keys(ObjC.classes)) {
    if (rx.test(name)) out.push(name);
  }
  return out.sort();
}

function listMethods(clsName) {
  const cls = ObjC.classes[clsName];
  if (!cls) return [];
  return cls.$ownMethods;
}

const classes = listClasses('MobileActivation|DeviceIdentity|MAD|DCRT|UCRT|BAA');
console.log('CLASSES:\n' + classes.join('\n'));

for (const c of classes) {
  const methods = listMethods(c).filter(m =>
    /dcrt|ucrt|baa|issue|cert|oob|reference/i.test(m)
  );
  if (methods.length) {
    console.log('\n== ' + c + ' ==');
    console.log(methods.join('\n'));
  }
}

// Exported C symbols
const mods = Process.enumerateModules().filter(m =>
  /MobileActivation|DeviceIdentity/i.test(m.name)
);
console.log('\nMODULES:');
for (const m of mods) {
  console.log(m.name, m.base, m.path);
  const exports = m.enumerateExports().filter(e =>
    /DCRT|UCRT|BAA|IssueClient|DeviceIdentity|NAC/i.test(e.name)
  );
  for (const e of exports.slice(0, 80)) {
    console.log('  ', e.type, e.name);
  }
}
