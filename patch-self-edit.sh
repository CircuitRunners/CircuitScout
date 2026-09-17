#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-self-edit.sh
#   An admin can edit their own account from Manage scouts.
#
#   Two guards blocked it: one in account.adminUpdateScout for name, team and
#   email, and one in profiles.adminResetTarget for the password. Both are
#   removed. Editing yourself through the admin panel is the same set of
#   changes the profile page already offers, and the password path verifies
#   the current password either way — for your own row, "your own password"
#   IS the current one, which is exactly the self-change flow.
#
#   Deleting yourself is still blocked in account.deleteScout. That one stays:
#   it would sign you out mid-action and is what the profile page is for.
#
# No schema change. Requires patch-account-edit.sh to have run first.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/account.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
grep -q "adminUpdateScout" convex/account.ts || {
  echo "ERROR: run patch-account-edit.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

say "Backend: drop both self-edit guards"
cat > /tmp/cs-self-edit.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (p, m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
// deleteScout opens with the same three lines as adminUpdateScout, so an
// anchor that looks unique is not. Every replacement here is counted first.
const count = (s, needle) => s.split(needle).length - 1;

// --- account.adminUpdateScout ------------------------------------------------
{
  const p = "convex/account.ts";
  let s = readFileSync(p, "utf8");
  const block = `    const me = await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That scout no longer exists.");
    if (target.userId === me.userId) {
      throw new Error("Edit your own account from your profile page.");
    }

    const fields = validate(args);`;
  const seen = count(s, block);
  if (seen === 0) {
    console.log("convex/account.ts: already patched");
  } else {
    if (seen > 1) fail(p, "the adminUpdateScout guard matched more than once");
    // `me` was only there for the self check, so the admin guard loses its
    // binding rather than being left dangling and unused.
    s = s.replace(block, `    await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That scout no longer exists.");

    const fields = validate(args);`);
    writeFileSync(p, s);
    console.log("convex/account.ts patched");
  }
}

// --- profiles.adminResetTarget ----------------------------------------------
{
  const p = "convex/profiles.ts";
  let s = readFileSync(p, "utf8");
  const guard = `    if (account.userId === args.adminUserId) {
      return { ok: false as const, reason: "Change your own password from your profile page." };
    }
`;
  if (!s.includes(guard)) {
    console.log("convex/profiles.ts: already patched");
  } else {
    s = s.replace(guard, "");
    writeFileSync(p, s);
    console.log("convex/profiles.ts patched");
  }
}
MJS
runjs /tmp/cs-self-edit.mjs
rm -f /tmp/cs-self-edit.mjs

say "Panel: wording that fits your own row"
cat > /tmp/cs-self-edit-ui.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("editingSelf")) { console.log("already patched"); process.exit(0); }

const emailValue = `  const emailValue = email ?? currentEmail ?? "";`;
if (!s.includes(emailValue)) fail("could not find the email value");

const passwordFields = `            <Label htmlFor={\`admin-pw-\${profile._id}\`}>Your own password</Label>
            <Input id={\`admin-pw-\${profile._id}\`} type="password"
              autoComplete="current-password" value={adminPassword}
              onChange={(e) => setAdminPassword(e.target.value)} />
            <p className="text-muted-foreground text-xs">
              Setting someone else's password needs yours. They are not told,
              so tell them what it is.
            </p>`;
if (!s.includes(passwordFields)) fail("could not find the admin password field");

s = s.replace(emailValue, `${emailValue}
  // Your own row reached through the admin panel. The password field is then
  // the ordinary current-password check, not an override.
  const editingSelf =
    myEmail != null && currentEmail != null && myEmail === currentEmail;`);

s = s.replace(passwordFields, `            <Label htmlFor={\`admin-pw-\${profile._id}\`}>
              {editingSelf ? "Your current password" : "Your own password"}
            </Label>
            <Input id={\`admin-pw-\${profile._id}\`} type="password"
              autoComplete="current-password" value={adminPassword}
              onChange={(e) => setAdminPassword(e.target.value)} />
            {editingSelf ? null : (
              <p className="text-muted-foreground text-xs">
                Setting someone else's password needs yours. They are not told,
                so tell them what it is.
              </p>
            )}`);

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
runjs /tmp/cs-self-edit-ui.mjs
rm -f /tmp/cs-self-edit-ui.mjs

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
