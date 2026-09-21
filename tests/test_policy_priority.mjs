// Run: node --test tests/test_policy_priority.mjs
// Execute only the two embedded AWK validators against synthetic rule output.
// Neither installer is sourced/executed; no networking or temporary files.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {test} from 'node:test';

const awkCommands = ['awk', 'gawk', 'mawk'].filter(command => {
    const result = spawnSync(command, ['BEGIN { exit 0 }'], {encoding: 'utf8'});
    return !result.error && result.status === 0;
});
assert.ok(awkCommands.length, 'At least one AWK interpreter is required');

function validator(source, name) {
    const start = source.indexOf(`\n${name}() {\n`);
    assert.ok(start >= 0, `Missing function: ${name}`);
    const end = source.indexOf('\n}\n', start);
    assert.ok(end > start, `Missing function end: ${name}`);
    const body = source.slice(start, end);
    const program = body.match(/\| awk -v pn=[^\n]* '\n([\s\S]*?)\n    '/);
    assert.ok(program, `Missing embedded rule validator: ${name}`);
    return program[1];
}

const baseline = (named = false) => [
    `0: from all lookup ${named ? 'local' : '255'}`,
    `32766: from all lookup ${named ? 'main' : '254'}`,
    `32767: from all lookup ${named ? 'default' : '253'}`,
];
const sourceNet = '10.9.0.0/24';

for (const file of ['install_amneziawg.sh', 'install_amneziawg_en.sh']) {
    const source = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
    const programs = {
        preflight: validator(source, 'preflight_fork_policy_namespace'),
        runtime: validator(source, 'verify_fork_egress_runtime'),
    };
    for (const awk of awkCommands) {
        function check(phase, rules, expected, label, priority = 789, table = 2408) {
            const result = spawnSync(awk, [
                '-v', `pn=${priority}`, '-v', `p=${priority}:`,
                '-v', `g=${priority + 1}:`, '-v', `t=${table}`,
                '-v', `s=${sourceNet}`, programs[phase],
            ], {input: `${rules.join('\n')}\n`, encoding: 'utf8'});
            assert.ifError(result.error);
            assert.equal(result.signal, null, `${label}: AWK was interrupted`);
            assert.equal(result.status, expected, `${phase}: ${label}\n${result.stderr}`);
        }
        function owned(priority = 789, table = 2408) {
            return [
                `${priority}: from ${sourceNet} lookup ${table}`,
                `${priority + 1}: from ${sourceNet} blackhole`,
            ];
        }

        test(`${file} / ${awk}: ordinary Linux rules pass numerically`, () => {
            for (const priority of [789, 456, 1, 9, 10, 100, 1000, 32764]) {
                for (const named of [false, true]) {
                    const table = priority === 456 ? 123 : 2408;
                    check('preflight', baseline(named), 0, `baseline at ${priority}`, priority, table);
                    check('runtime', [...baseline(named), ...owned(priority, table)], 0,
                        `owned runtime at ${priority}`, priority, table);
                }
            }
        });

        test(`${file} / ${awk}: earlier rules rejected, later unrelated rules accepted`, () => {
            for (const phase of Object.keys(programs)) {
                for (const priority of [456, 789]) {
                    const rules = [...baseline(), ...(phase === 'runtime' ? owned(priority) : [])];
                    check(phase, [...rules, '9: from all lookup 100'], 1,
                        '9 precedes a three-digit priority', priority);
                    check(phase, [...rules, '1000: from all lookup 100'], 0,
                        '1000 follows a three-digit priority', priority);
                }
            }
        });

        test(`${file} / ${awk}: namespace and ownership protections remain enforced`, () => {
            for (const rule of [
                '789: from all lookup 100',
                '790: from all blackhole',
                '40000: from all lookup 2408',
                '0: from all lookup 100',
                '0: from all lookup 255',
            ]) {
                check('preflight', [...baseline(), rule], 1, `reject ${rule}`);
                check('runtime', [...baseline(), ...owned(), rule], 1, `reject ${rule}`);
            }
            check('preflight', baseline().slice(1), 1, 'missing local rule');
            check('runtime', baseline(), 1, 'missing owned rules');
            check('runtime', [...baseline().slice(1), ...owned()], 1, 'missing local rule');
            check('runtime', [...baseline(), owned()[0]], 1, 'missing blackhole guard');
            check('runtime', [...baseline(), owned()[1]], 1, 'missing primary rule');
            check('runtime', [...baseline(), ...owned(), owned()[0]], 1, 'duplicate primary rule');
            check('runtime', [...baseline(), ...owned(), owned()[1]], 1, 'duplicate guard');
            check('runtime', [...baseline(), '789: from all lookup 2408', owned()[1]], 1,
                'wrong source network');
        });
    }
}
