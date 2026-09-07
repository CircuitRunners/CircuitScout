#!/usr/bin/env bash
# Adds a detail textbox for Swerve (and fixes the unbound "Other" input).
# Run once from the REPO ROOT.
set -euo pipefail
[[ -f src/routes/pit/form.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }

cat > /tmp/patch-dt.mjs <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
const path = "src/routes/pit/form.tsx";
let s = readFileSync(path, "utf8");
const before = s;

// 1. Split drivetrain into a base choice plus free-text detail.
s = s.replace("  drivetrain: string;", "  drivetrainBase: string;\n  drivetrainDetail: string;");
s = s.replace('  drivetrain: "", underTrench: false, overBump: false,',
              '  drivetrainBase: "", drivetrainDetail: "", underTrench: false, overBump: false,');

// 2. Hydrate: the stored value is "Base — detail".
s = s.replace("        drivetrain: report.drivetrain,",
`        drivetrainBase: report.drivetrain.split(" — ")[0] ?? "",
        drivetrainDetail: report.drivetrain.split(" — ").slice(1).join(" — "),`);

// 3. Recombine on save.
s = s.replace("        drivetrain: form.drivetrain,",
`        drivetrain: form.drivetrainDetail.trim()
          ? \`\${form.drivetrainBase} — \${form.drivetrainDetail.trim()}\`
          : form.drivetrainBase,`);

// 4. The picker, with a bound detail input for Swerve and Other.
const oldUI = `            <div className="grid grid-cols-2 gap-2">
              {DRIVETRAINS.map((option) => (
                <Button
                  key={option}
                  variant={form.drivetrain === option ? "default" : "outline"}
                  className="h-12"
                  onClick={() => set("drivetrain", option)}
                >
                  {option}
                </Button>
              ))}
            </div>
            {form.drivetrain === "Other" ? (
              <Input
                placeholder="Drivetrain type"
                onChange={(e) => set("drivetrain", e.target.value)}
              />
            ) : null}`;

const newUI = `            <div className="grid grid-cols-2 gap-2">
              {DRIVETRAINS.map((option) => (
                <Button
                  key={option}
                  variant={form.drivetrainBase === option ? "default" : "outline"}
                  className="h-12"
                  onClick={() => set("drivetrainBase", option)}
                >
                  {option}
                </Button>
              ))}
            </div>
            {form.drivetrainBase === "Swerve" ? (
              <Input
                placeholder="Which swerve? e.g. MK4i, MK4n, SwerveX"
                value={form.drivetrainDetail}
                onChange={(e) => set("drivetrainDetail", e.target.value)}
              />
            ) : null}
            {form.drivetrainBase === "Other" ? (
              <Input
                placeholder="Describe the drivetrain"
                value={form.drivetrainDetail}
                onChange={(e) => set("drivetrainDetail", e.target.value)}
              />
            ) : null}`;

if (!s.includes(oldUI)) {
  console.error("Could not find the drivetrain picker — has form.tsx been edited?");
  process.exit(1);
}
s = s.replace(oldUI, newUI);

if (s === before) { console.error("Nothing changed."); process.exit(1); }
writeFileSync(path, s);
console.log("src/routes/pit/form.tsx patched");
EOF

bun /tmp/patch-dt.mjs
rm -f /tmp/patch-dt.mjs
bun run typecheck || echo "Typecheck reported issues — see above."
