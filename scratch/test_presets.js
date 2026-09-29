import { OmniBusAssembler } from "../web_ide/js/assembler.js";
import { PRESETS } from "../web_ide/js/presets.js";

const asm = new OmniBusAssembler(50000000);
let failed = 0;

for (const p of PRESETS) {
    const res = asm.assemble(p.code);
    if (!res.success) {
        console.error(`[FAIL] Preset ${p.id} (${p.title}):`, res.errors);
        failed++;
    } else {
        console.log(`[PASS] Preset ${p.id} (${p.title}): ${res.machineCode.length} words assembled.`);
    }
}

if (failed === 0) {
    console.log("\nALL 8 PRESETS ASSEMBLED SUCCESSFULLY WITH ZERO ERRORS!");
} else {
    process.exit(1);
}
