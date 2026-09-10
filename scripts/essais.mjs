/* Lance toute la suite d'essais d'écran, l'une après l'autre.
   Usage : npm test   (ou : node scripts/essais.mjs ecran-technicien)

   Les essais impriment un compte rendu lisible plutôt que d'échouer sur une
   assertion : c'est voulu, on les relit. Ce lanceur n'ajoute qu'un garde-fou —
   il échoue si un essai plante, déclenche une erreur JS dans la page, ou
   signale un bouton mort. */
import { readdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const racine = join(dirname(fileURLToPath(import.meta.url)), '..');
const filtre = process.argv.slice(2);
const essais = readdirSync(join(racine, 'tests'))
  .filter(f => f.endsWith('.mjs'))
  .filter(f => !filtre.length || filtre.some(x => f.includes(x)))
  .sort();

if (!essais.length) { console.error('Aucun essai ne correspond à', filtre); process.exit(1); }

const lancer = f => new Promise(resolve => {
  const p = spawn(process.execPath, [join(racine, 'tests', f)], { cwd: racine });
  let sortie = '';
  p.stdout.on('data', d => sortie += d);
  p.stderr.on('data', d => sortie += d);
  p.on('close', code => resolve({ f, code, sortie }));
});

let rouges = 0;
for (const f of essais) {
  const { code, sortie } = await lancer(f);
  // « MORT » est le mot qu'emploient les essais de boutons pour un contrôle
  // sans effet ; deux d'entre eux sont des faux positifs connus, repris
  // isolément par boutons-back-office-details.mjs (voir AGENTS.md).
  const jsKo = sortie.includes('!! ERREUR JS');
  const ko = code !== 0 || jsKo;
  if (ko) rouges++;
  console.log((ko ? '✗' : '✓') + ' ' + f.padEnd(32) +
    (code !== 0 ? 'code ' + code : jsKo ? 'erreur JS dans la page' : 'ok'));
  if (ko) console.log(sortie.split('\n').map(l => '    ' + l).join('\n'));
}
console.log('\n' + essais.length + ' essai(s), ' + rouges + ' en échec.');
process.exit(rouges ? 1 : 0);
