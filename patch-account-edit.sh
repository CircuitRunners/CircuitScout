#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-account-edit.sh
#   1. "Change email" on the account page, left of "Change password".
#   2. "Edit account" in Manage scouts, left of "Delete" — an admin can set a
#      scout's email, password, first name, last initial and team number.
#
# Two things worth knowing before running it.
#
# An email lives in two rows: the authAccounts row it is looked up by at
# sign-in, and the users row everything else reads. Both move together here,
# or the person cannot sign in. Convex Auth exposes no API for this, so the
# rows are patched directly — the same approach account.deleteSelf already
# takes to clear them.
#
# An admin resetting someone else's password goes through a new credentials
# provider, because modifyAccountCredentials only works inside one. The
# provider verifies the ADMIN's own password and returns the ADMIN's user id,
# so the admin stays signed in as themselves rather than as the scout.
#
# No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/account.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

# --- 1. profiles.ts: export validate, add the reset check -------------------
say "Profiles: export validate, add the admin reset check"
cat > /tmp/cs-profiles.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/profiles.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("adminResetTarget")) { console.log("already patched"); process.exit(0); }

const decl = `function validate(args: {`;
if (!s.includes(decl)) fail("could not find the validate helper");
s = s.replace(decl, `export function validate(args: {`);

s += `
/**
 * Checked by the admin password-reset provider, which runs before any session
 * exists — so the admin is identified by the password they just proved, not
 * by ctx.auth.
 */
export const adminResetTarget = internalQuery({
  args: { adminUserId: v.id("users"), targetEmail: v.string() },
  handler: async (ctx, args) => {
    const admin = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", args.adminUserId))
      .unique();
    if (admin?.role !== "admin") {
      return { ok: false as const, reason: "Only a full admin can reset a password." };
    }

    const account = await ctx.db
      .query("authAccounts")
      .withIndex("providerAndAccountId", (q) =>
        q.eq("provider", "password").eq("providerAccountId", args.targetEmail))
      .unique();
    if (!account) {
      return { ok: false as const, reason: "That scout has no password sign-in." };
    }
    if (account.userId === args.adminUserId) {
      return { ok: false as const, reason: "Change your own password from your profile page." };
    }
    return { ok: true as const, reason: "" };
  },
});
`;

writeFileSync(p, s);
console.log("convex/profiles.ts patched");
MJS
runjs /tmp/cs-profiles.mjs
rm -f /tmp/cs-profiles.mjs

# --- 2. auth.ts: the admin reset provider -----------------------------------
say "Auth: admin password-reset provider"
cat > /tmp/cs-auth.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/auth.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("admin-password-reset")) { console.log("already patched"); process.exit(0); }

const imports = `import type { DataModel } from "./_generated/dataModel";`;
if (!s.includes(imports)) fail("could not find the DataModel import");

const exportLine = `export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password, PasswordChange],
});`;
if (!s.includes(exportLine)) fail("could not find the convexAuth call");

s = s.replace(imports, `import { internal } from "./_generated/api";
import type { DataModel } from "./_generated/dataModel";`);

s = s.replace(exportLine, `/**
 * An admin setting someone else's password. The admin proves their OWN
 * password, and the provider returns the ADMIN's user id — returning the
 * target's would sign the admin in as the scout they were trying to help.
 */
const AdminPasswordReset = ConvexCredentials<DataModel>({
  id: "admin-password-reset",
  authorize: async (params, ctx) => {
    const adminEmail = String(params.adminEmail ?? "");
    const adminPassword = String(params.adminPassword ?? "");
    const targetEmail = String(params.targetEmail ?? "");
    const newPassword = String(params.newPassword ?? "");

    if (newPassword.length < 8) {
      throw new Error("The new password must be at least 8 characters.");
    }

    const admin = await retrieveAccount(ctx, {
      provider: "password",
      account: { id: adminEmail, secret: adminPassword },
    });
    if (!admin) throw new Error("Your password is incorrect.");

    // Role and target are checked in the database: a valid password alone is
    // any signed-up scout, not an admin.
    const check = await ctx.runQuery(internal.profiles.adminResetTarget, {
      adminUserId: admin.user._id,
      targetEmail,
    });
    if (!check.ok) throw new Error(check.reason);

    await modifyAccountCredentials(ctx, {
      provider: "password",
      account: { id: targetEmail, secret: newPassword },
    });

    return { userId: admin.user._id };
  },
});

export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password, PasswordChange, AdminPasswordReset],
});`);

writeFileSync(p, s);
console.log("convex/auth.ts patched");
MJS
runjs /tmp/cs-auth.mjs
rm -f /tmp/cs-auth.mjs

# --- 3. account.ts: email moves, and the admin edit -------------------------
say "Account: change email, admin edit"
if grep -q "adminUpdateScout" convex/account.ts; then
  echo "already patched"
else
  cat >> convex/account.ts <<'TS'

/**
 * Renames a password sign-in. The address lives in two rows — the authAccounts
 * row it is looked up by, and the users row every other surface reads — so
 * both move together or the person is locked out. Convex Auth has no API for
 * this, so the rows are patched directly, as purgeUser above already does.
 *
 * Stored as typed rather than lowercased, because sign-in compares the address
 * exactly as it was entered at sign-up. The clash check is case-insensitive
 * regardless: two accounts differing only in case would be a trap.
 */
async function setEmail(ctx: MutationCtx, userId: Id<"users">, raw: string) {
  const email = raw.trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("That does not look like an email address.");
  }

  const accounts = await ctx.db
    .query("authAccounts")
    .filter((q) => q.eq(q.field("provider"), "password"))
    .collect();

  const taken = accounts.find(
    (account) =>
      account.userId !== userId
      && account.providerAccountId.toLowerCase() === email.toLowerCase(),
  );
  if (taken) throw new Error("Another account already uses that email.");

  const mine = accounts.filter((account) => account.userId === userId);
  if (mine.length === 0) throw new Error("That account has no password sign-in.");

  for (const account of mine) {
    await ctx.db.patch(account._id, { providerAccountId: email });
  }
  await ctx.db.patch(userId, { email });
  return email;
}

/**
 * The caller's own email. The client signs in again with the current password
 * immediately before calling this — the same check deleteSelf trusts, and it
 * avoids a second password path to get wrong.
 */
export const changeEmail = mutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    return { email: await setEmail(ctx, userId, args.email) };
  },
});

/** One scout's sign-in email, for the admin edit panel. Full admins only. */
export const scoutEmail = query({
  args: { profileId: v.id("profiles") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const target = await ctx.db.get(args.profileId);
    if (!target) return null;
    const user = await ctx.db.get(target.userId);
    return user?.email ?? null;
  },
});

/**
 * Name, team and email for someone else. Password is not here — that has to go
 * through the admin-password-reset provider, which is the only place the
 * credential helpers can be called.
 *
 * A team number set by an admin applies immediately rather than raising a join
 * request: the person who would approve it is the one typing.
 */
export const adminUpdateScout = mutation({
  args: {
    profileId: v.id("profiles"),
    email: v.optional(v.string()),
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That scout no longer exists.");
    if (target.userId === me.userId) {
      throw new Error("Edit your own account from your profile page.");
    }

    const fields = validate(args);
    await ctx.db.patch(target._id, fields);

    // Their team was just decided by hand, so a request to join one is moot.
    const joins = await ctx.db
      .query("teamJoins")
      .withIndex("by_profile", (q) => q.eq("profileId", target._id))
      .collect();
    for (const join of joins) {
      if (join.status === "pending") await ctx.db.delete(join._id);
    }

    if (args.email !== undefined && args.email.trim() !== "") {
      await setEmail(ctx, target.userId, args.email);
    }

    return { displayName: fields.displayName };
  },
});
TS
  cat > /tmp/cs-account-imports.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/account.ts";
let s = readFileSync(p, "utf8");
const old = `import { requireAdmin, requireUser } from "./lib/guards";`;
if (!s.includes(old)) {
  console.error("ABORT: could not find the guards import in convex/account.ts");
  process.exit(1);
}
s = s.replace(old, `import { requireAdmin, requireUser } from "./lib/guards";
import { validate } from "./profiles";`);
writeFileSync(p, s);
console.log("convex/account.ts patched");
MJS
  runjs /tmp/cs-account-imports.mjs
  rm -f /tmp/cs-account-imports.mjs
fi

# --- 4. Account page: change email ------------------------------------------
say "Account page: change email"
cat > /tmp/cs-profile-page.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/profile.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("changeEmail")) { console.log("already patched"); process.exit(0); }

const state = `  const [mode, setMode] = useState<"none" | "password" | "delete">("none");`;
if (!s.includes(state)) fail("could not find the mode state");

const close = `  const close = () => {
    setMode("none");
    setCurrent(""); setNext(""); setConfirm("");
    setDeletePassword(""); setDeleteConfirmed(false);
  };`;
if (!s.includes(close)) fail("could not find the close helper");

const changePasswordFn = `  const changePassword = async () => {`;
if (!s.includes(changePasswordFn)) fail("could not find changePassword");

const buttons = `          <Button variant="outline" onClick={() => setMode("password")}>
            Change password
          </Button>`;
if (!s.includes(buttons)) fail("could not find the change password button");

const passwordDialog = `      <Dialog open={mode === "password"} onOpenChange={(o) => { if (!o) close(); }}>`;
if (!s.includes(passwordDialog)) fail("could not find the password dialog");

s = s.replace(`  const deleteSelf = useMutation(api.account.deleteSelf);`,
  `  const deleteSelf = useMutation(api.account.deleteSelf);
  const changeEmail = useMutation(api.account.changeEmail);`);

s = s.replace(state,
  `  const [mode, setMode] = useState<"none" | "email" | "password" | "delete">("none");
  const [newEmail, setNewEmail] = useState("");
  const [emailPassword, setEmailPassword] = useState("");`);

s = s.replace(close, `  const close = () => {
    setMode("none");
    setCurrent(""); setNext(""); setConfirm("");
    setNewEmail(""); setEmailPassword("");
    setDeletePassword(""); setDeleteConfirmed(false);
  };`);

s = s.replace(changePasswordFn, `  const changeMyEmail = async () => {
    setBusy(true);
    try {
      // Same re-verification the delete path uses: a stolen open session must
      // not be enough to move the address a password reset would go to.
      await signIn("password", { email, password: emailPassword, flow: "signIn" });
      const result = await changeEmail({ email: newEmail });
      toast.success(\`Email changed to \${result.email}\`);
      close();
    } catch (error) {
      toast.error("Could not change it", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const changePassword = async () => {`);

s = s.replace(buttons, `          <Button variant="outline" onClick={() => setMode("email")}>
            Change email
          </Button>
${buttons}`);

s = s.replace(passwordDialog, `      <Dialog open={mode === "email"} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Change email</DialogTitle>
            <DialogDescription>
              This is what you sign in with. You are currently {email}.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label htmlFor="new-email">New email</Label>
              <Input id="new-email" type="email" autoComplete="email"
                value={newEmail} onChange={(e) => setNewEmail(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="email-pw">Your password</Label>
              <Input id="email-pw" type="password" autoComplete="current-password"
                value={emailPassword}
                onChange={(e) => setEmailPassword(e.target.value)} />
            </div>
            <Button className="w-full"
              disabled={busy || emailPassword === "" || !newEmail.includes("@")
                || newEmail.trim() === email}
              onClick={() => void changeMyEmail()}>
              Change email
            </Button>
          </div>
        </DialogContent>
      </Dialog>

${passwordDialog}`);

writeFileSync(p, s);
console.log("src/routes/profile.tsx patched");
MJS
runjs /tmp/cs-profile-page.mjs
rm -f /tmp/cs-profile-page.mjs

# --- 5. Manage scouts: edit account -----------------------------------------
say "Manage scouts: edit account"
cat > /tmp/cs-roles.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("EditScoutPanel")) { console.log("already patched"); process.exit(0); }

const imports = `import { useMutation, useQuery } from "convex/react";
import { ChevronDown, TriangleAlert, Trash2, UserMinus, Users, X } from "lucide-react";`;
if (!s.includes(imports)) fail("could not find the imports");

const label = `import { Input } from "@/components/ui/input";`;
if (!s.includes(label)) fail("could not find the Input import");

const state = `  const [targetId, setTargetId] = useState<string | null>(null);`;
if (!s.includes(state)) fail("could not find the manage-scouts state");

const rowControls = `                    {profile.role === "admin" ? (
                      <Badge variant="secondary">Admin</Badge>
                    ) : (
                      <Button size="sm" variant="destructive"
                        onClick={() => {
                          setTargetId(targetId === profile._id ? null : profile._id);
                          setConfirmName("");
                        }}>
                        <Trash2 className="size-3" /> Delete
                      </Button>
                    )}`;
if (!s.includes(rowControls)) fail("could not find the row controls");

const deletePanel = `                  {targetId === profile._id ? (`;
if (!s.includes(deletePanel)) fail("could not find the delete panel");

const componentStart = `export function RolesTable() {`;
if (!s.includes(componentStart)) fail("could not find RolesTable");

s = s.replace(imports, `import { useMutation, useQuery } from "convex/react";
import { useAuthActions } from "@convex-dev/auth/react";
import { ChevronDown, TriangleAlert, Trash2, UserMinus, UserPen, Users, X } from "lucide-react";`);

s = s.replace(label, `import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";`);

// The panel is its own component so it can hold the scout's email query — a
// hook cannot live inside the row map.
s = s.replace(componentStart, `/**
 * Editing someone else's account. Everything except the password goes through
 * one mutation; the password has to go through the admin-password-reset
 * provider, which is why this asks the admin for their own password too.
 */
function EditScoutPanel({
  profile, onDone,
}: {
  profile: {
    _id: Id<"profiles">;
    displayName: string;
    firstName?: string;
    lastInitial?: string;
    teamNumber?: number;
  };
  onDone: () => void;
}) {
  const { signIn } = useAuthActions();
  const myEmail = useQuery(api.account.myEmail);
  const currentEmail = useQuery(api.account.scoutEmail, { profileId: profile._id });
  const update = useMutation(api.account.adminUpdateScout);

  // Null means "not edited yet", so the live query can fill the field without
  // overwriting what is being typed.
  const [email, setEmail] = useState<string | null>(null);
  const [firstName, setFirstName] = useState(profile.firstName ?? "");
  const [lastInitial, setLastInitial] = useState(profile.lastInitial ?? "");
  const [teamNumber, setTeamNumber] = useState(
    profile.teamNumber ? String(profile.teamNumber) : "");
  const [newPassword, setNewPassword] = useState("");
  const [adminPassword, setAdminPassword] = useState("");
  const [busy, setBusy] = useState(false);

  const emailValue = email ?? currentEmail ?? "";
  const team = Number.parseInt(teamNumber, 10);
  const ready =
    firstName.trim() !== ""
    && /^[A-Za-z]$/.test(lastInitial.trim())
    && Number.isInteger(team) && team > 0
    && emailValue.includes("@")
    && (newPassword === "" || (newPassword.length >= 8 && adminPassword !== ""));

  const save = async () => {
    setBusy(true);
    try {
      // Password first: the reset is addressed to the email they have now, so
      // changing the address before it would aim at an account that moved.
      if (newPassword !== "") {
        if (!myEmail) throw new Error("Could not read your own email.");
        if (!currentEmail) throw new Error("That scout has no email on file.");
        await signIn("admin-password-reset", {
          adminEmail: myEmail,
          adminPassword,
          targetEmail: currentEmail,
          newPassword,
        });
      }
      const result = await update({
        profileId: profile._id,
        email: emailValue.trim() === (currentEmail ?? "") ? undefined : emailValue,
        firstName,
        lastInitial,
        teamNumber: team,
      });
      toast.success(\`\${result.displayName} updated\`);
      onDone();
    } catch (error) {
      toast.error("Could not save", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3 rounded-md border border-dashed p-3">
      <div className="space-y-2">
        <Label htmlFor={\`email-\${profile._id}\`}>Email</Label>
        <Input id={\`email-\${profile._id}\`} type="email" value={emailValue}
          onChange={(e) => setEmail(e.target.value)} />
      </div>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-2">
          <Label htmlFor={\`first-\${profile._id}\`}>First name</Label>
          <Input id={\`first-\${profile._id}\`} value={firstName}
            onChange={(e) => setFirstName(e.target.value)} />
        </div>
        <div className="space-y-2">
          <Label htmlFor={\`initial-\${profile._id}\`}>Last initial</Label>
          <Input id={\`initial-\${profile._id}\`} maxLength={1} value={lastInitial}
            onChange={(e) => setLastInitial(e.target.value)} />
        </div>
      </div>

      <div className="space-y-2">
        <Label htmlFor={\`team-\${profile._id}\`}>Team number</Label>
        <Input id={\`team-\${profile._id}\`} inputMode="numeric" value={teamNumber}
          onChange={(e) => setTeamNumber(e.target.value)} />
      </div>

      <div className="space-y-2 border-t pt-3">
        <Label htmlFor={\`pw-\${profile._id}\`}>New password</Label>
        <Input id={\`pw-\${profile._id}\`} type="password" autoComplete="new-password"
          placeholder="Leave blank to keep it" value={newPassword}
          onChange={(e) => setNewPassword(e.target.value)} />
        {newPassword !== "" ? (
          <>
            <Label htmlFor={\`admin-pw-\${profile._id}\`}>Your own password</Label>
            <Input id={\`admin-pw-\${profile._id}\`} type="password"
              autoComplete="current-password" value={adminPassword}
              onChange={(e) => setAdminPassword(e.target.value)} />
            <p className="text-muted-foreground text-xs">
              Setting someone else's password needs yours. They are not told,
              so tell them what it is.
            </p>
          </>
        ) : null}
      </div>

      <div className="flex gap-2">
        <Button size="sm" disabled={busy || !ready} onClick={() => void save()}>
          Save changes
        </Button>
        <Button size="sm" variant="ghost" onClick={onDone}>Cancel</Button>
      </div>
    </div>
  );
}

${componentStart}`);

s = s.replace(state, `  const [targetId, setTargetId] = useState<string | null>(null);
  const [editId, setEditId] = useState<string | null>(null);`);

s = s.replace(rowControls, `                    <Button size="sm" variant="outline"
                      onClick={() => {
                        setEditId(editId === profile._id ? null : profile._id);
                        setTargetId(null);
                      }}>
                      <UserPen className="size-3" /> Edit account
                    </Button>
${rowControls}`);

s = s.replace(deletePanel, `                  {editId === profile._id ? (
                    <EditScoutPanel profile={profile}
                      onDone={() => setEditId(null)} />
                  ) : null}

${deletePanel}`);

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
runjs /tmp/cs-roles.mjs
rm -f /tmp/cs-roles.mjs

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
