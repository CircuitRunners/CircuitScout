#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-account.sh
#   1. Change password (profile page)
#   2. Delete my account (profile page)
#   3. Manage scouts — full admin only — with delete
#
# Convex Auth has no public "change password" or "delete account" API, so:
#   - password change goes through a custom ConvexCredentials provider, which
#     is the documented extension point and the only place the credential
#     helpers can be called
#   - both destructive paths verify the password by attempting a normal sign
#     in first, which is the same check the auth system already trusts
#
# No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Auth: password-change provider"
cat > convex/auth.ts <<'EOF'
import { convexAuth } from "@convex-dev/auth/server";
import { Password } from "@convex-dev/auth/providers/Password";
import ConvexCredentials from "@convex-dev/auth/providers/ConvexCredentials";
import { modifyAccountCredentials, retrieveAccount } from "@convex-dev/auth/server";
import type { DataModel } from "./_generated/dataModel";

/**
 * Changing a password is not part of the Password provider's flows, and the
 * credential helpers can only be called with the auth-aware context a provider
 * gets. So it is a provider of its own, invoked as
 * signIn("password-change", { email, currentPassword, newPassword }).
 */
const PasswordChange = ConvexCredentials<DataModel>({
  id: "password-change",
  authorize: async (params, ctx) => {
    const email = String(params.email ?? "");
    const currentPassword = String(params.currentPassword ?? "");
    const newPassword = String(params.newPassword ?? "");

    if (newPassword.length < 8) {
      throw new Error("The new password must be at least 8 characters.");
    }

    // Re-checking the old password is the whole point: a stolen open session
    // should not be enough to lock the owner out of their own account.
    const existing = await retrieveAccount(ctx, {
      provider: "password",
      account: { id: email, secret: currentPassword },
    });
    if (!existing) throw new Error("Current password is incorrect.");

    await modifyAccountCredentials(ctx, {
      provider: "password",
      account: { id: email, secret: newPassword },
    });

    return { userId: existing.user._id };
  },
});

export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password, PasswordChange],
});
EOF

say "Convex: account deletion"
cat > convex/account.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireAdmin, requireUser } from "./lib/guards";
import type { Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";

/**
 * Removes a user and everything that identifies them, leaving their scouting
 * data in place. Reports keep pointing at a user id that no longer resolves,
 * and every surface already renders that as "Unknown scout" — deleting the
 * observations would quietly change every average the person contributed to.
 *
 * Convex Auth exposes no deletion API, so the auth rows are cleared directly.
 * Sessions and refresh tokens go first: a live session outliving the account
 * would be a signed-in ghost.
 */
async function purgeUser(ctx: MutationCtx, userId: Id<"users">) {
  const sessions = await ctx.db
    .query("authSessions")
    .filter((q) => q.eq(q.field("userId"), userId))
    .collect();
  for (const session of sessions) {
    const tokens = await ctx.db
      .query("authRefreshTokens")
      .filter((q) => q.eq(q.field("sessionId"), session._id))
      .collect();
    for (const token of tokens) await ctx.db.delete(token._id);
    await ctx.db.delete(session._id);
  }

  const accounts = await ctx.db
    .query("authAccounts")
    .filter((q) => q.eq(q.field("userId"), userId))
    .collect();
  for (const account of accounts) await ctx.db.delete(account._id);

  const profile = await ctx.db
    .query("profiles")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();
  if (profile) {
    const joins = await ctx.db
      .query("teamJoins")
      .withIndex("by_profile", (q) => q.eq("profileId", profile._id))
      .collect();
    for (const join of joins) await ctx.db.delete(join._id);
    await ctx.db.delete(profile._id);
  }

  await ctx.db.delete(userId);
}

/**
 * The caller's own account. The client verifies the password by signing in
 * again immediately before calling this — the same check the auth system
 * already trusts, and it avoids a second password path to get wrong.
 */
export const deleteSelf = mutation({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();

    // Losing the last admin locks everyone out of role management.
    if (profile?.role === "admin") {
      const admins = (await ctx.db.query("profiles").collect())
        .filter((p) => p.role === "admin");
      if (admins.length <= 1) {
        throw new Error(
          "You are the only admin. Promote someone else before deleting your account.",
        );
      }
    }

    await purgeUser(ctx, userId);
  },
});

/** The signed-in user's email, needed to re-verify a password. */
export const myEmail = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const user = await ctx.db.get(userId);
    return user?.email ?? null;
  },
});

/** Full admins only — deleting someone else's account is not a team matter. */
export const deleteScout = mutation({
  args: { profileId: v.id("profiles") },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That scout no longer exists.");
    if (target.userId === me.userId) {
      throw new Error("Delete your own account from your profile page.");
    }
    if (target.role === "admin") {
      throw new Error("Demote them first — an admin cannot be deleted outright.");
    }

    await purgeUser(ctx, target.userId);
    return { displayName: target.displayName };
  },
});
EOF

say "Profile page: password and delete"
cat > /tmp/ac.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/profile.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("AccountSecurity")) { console.log("already patched"); process.exit(0); }

s = s.replace("  const ensure = useAction(api.tba.claimProfile);",
  "  const email = useQuery(api.account.myEmail);\n  const ensure = useAction(api.tba.claimProfile);");
if (!s.includes("api.account.myEmail")) fail("could not add the email query");

s = s.replace('import { useAction, useQuery } from "convex/react";',
  'import { useAction, useMutation, useQuery } from "convex/react";\nimport { useAuthActions } from "@convex-dev/auth/react";');
s = s.replace('import { Input } from "@/components/ui/input";',
  'import { Input } from "@/components/ui/input";\nimport {\n  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,\n} from "@/components/ui/dialog";');

s = s.replace("export default function ProfilePage() {", `function AccountSecurity({ email }: { email: string }) {
  const { signIn, signOut } = useAuthActions();
  const deleteSelf = useMutation(api.account.deleteSelf);

  const [mode, setMode] = useState<"none" | "password" | "delete">("none");
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [deletePassword, setDeletePassword] = useState("");
  const [deleteConfirmed, setDeleteConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);

  const close = () => {
    setMode("none");
    setCurrent(""); setNext(""); setConfirm("");
    setDeletePassword(""); setDeleteConfirmed(false);
  };

  const changePassword = async () => {
    if (next !== confirm) {
      toast.error("The new passwords do not match.");
      return;
    }
    setBusy(true);
    try {
      await signIn("password-change", {
        email, currentPassword: current, newPassword: next,
      });
      toast.success("Password changed");
      close();
    } catch (error) {
      toast.error("Could not change it", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const removeAccount = async () => {
    setBusy(true);
    try {
      // Verifying by signing in again is the same check the auth system
      // already trusts, and avoids a second password path to get wrong.
      await signIn("password", {
        email, password: deletePassword, flow: "signIn",
      });
      await deleteSelf({});
      toast.success("Account deleted");
      await signOut();
    } catch (error) {
      toast.error("Could not delete the account", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Account</CardTitle>
          <CardDescription>
            Deleting your account removes your sign-in. Reports and pit scouting
            you wrote stay where they are — removing them would change every
            average you contributed to.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={() => setMode("password")}>
            Change password
          </Button>
          <Button variant="destructive" onClick={() => setMode("delete")}>
            Delete account
          </Button>
        </CardContent>
      </Card>

      <Dialog open={mode === "password"} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Change password</DialogTitle>
            <DialogDescription>
              At least 8 characters.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label htmlFor="current-pw">Current password</Label>
              <Input id="current-pw" type="password" autoComplete="current-password"
                value={current} onChange={(e) => setCurrent(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="new-pw">New password</Label>
              <Input id="new-pw" type="password" autoComplete="new-password"
                value={next} onChange={(e) => setNext(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirm-pw">Confirm new password</Label>
              <Input id="confirm-pw" type="password" autoComplete="new-password"
                value={confirm} onChange={(e) => setConfirm(e.target.value)} />
            </div>
            {next !== "" && confirm !== "" && next !== confirm ? (
              <p className="text-destructive text-xs">They do not match.</p>
            ) : null}
            <Button className="w-full"
              disabled={busy || current === "" || next.length < 8 || next !== confirm}
              onClick={() => void changePassword()}>
              Change password
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={mode === "delete"} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Delete your account</DialogTitle>
            <DialogDescription>
              This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label htmlFor="del-pw">Your password</Label>
              <Input id="del-pw" type="password" autoComplete="current-password"
                value={deletePassword}
                onChange={(e) => setDeletePassword(e.target.value)} />
            </div>
            {!deleteConfirmed ? (
              <Button variant="outline" className="w-full"
                disabled={deletePassword === ""}
                onClick={() => setDeleteConfirmed(true)}>
                Continue
              </Button>
            ) : (
              <>
                <p className="text-destructive text-sm">
                  Your sign-in will be removed and you will be signed out.
                  Everything you scouted stays.
                </p>
                <Button variant="destructive" className="w-full" disabled={busy}
                  onClick={() => void removeAccount()}>
                  Delete my account permanently
                </Button>
              </>
            )}
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

export default function ProfilePage() {`);

const anchor = `      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Role</CardTitle>`;
if (!s.includes(anchor)) fail("could not find the Role card");
s = s.replace(anchor, `      {email ? <AccountSecurity email={email} /> : null}

${anchor}`);

writeFileSync(p, s);
console.log("src/routes/profile.tsx patched");
MJS
bun /tmp/ac.mjs
rm -f /tmp/ac.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."

say "Admin: manage scouts"
cat > /tmp/ms.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("manageOpen")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { ChevronDown, TriangleAlert, UserMinus, X } from "lucide-react";',
              'import { ChevronDown, TriangleAlert, Trash2, UserMinus, Users, X } from "lucide-react";');
s = s.replace("  const dismissDeparture = useMutation(api.profiles.dismissDeparture);",
`  const dismissDeparture = useMutation(api.profiles.dismissDeparture);
  const deleteScout = useMutation(api.account.deleteScout);`);

s = s.replace("  const [teamSearch, setTeamSearch] = useState(\"\");",
`  const [teamSearch, setTeamSearch] = useState("");

  const [manageOpen, setManageOpen] = useState(false);
  const [manageSearch, setManageSearch] = useState("");
  const [confirmName, setConfirmName] = useState("");
  const [targetId, setTargetId] = useState<string | null>(null);`);

// the manage button sits next to the team filter
const filterAnchor = `              <Button variant="outline" className="w-full justify-between"
                onClick={() => setPickerOpen(!pickerOpen)}>`;
if (!s.includes(filterAnchor)) fail("could not find the team filter button");
s = s.replace(`            <div className="space-y-2">
${filterAnchor}`,
`            <div className="space-y-2">
              <div className="flex gap-2">
              <Button variant="outline" className="flex-1 justify-between"
                onClick={() => setPickerOpen(!pickerOpen)}>`);
s = s.replace(`                <ChevronDown className={\`size-4 transition-transform \${pickerOpen ? "rotate-180" : ""}\`} />
              </Button>
`,
`                <ChevronDown className={\`size-4 transition-transform \${pickerOpen ? "rotate-180" : ""}\`} />
              </Button>
              <Button variant="outline" onClick={() => setManageOpen(true)}>
                <Users className="size-4" /> Manage scouts
              </Button>
              </div>
`);

s += `
`;

// the dialog itself, appended before the final closing fragment
const closeAnchor = `    </>
  );
}`;
if (!s.includes(closeAnchor)) fail("could not find the component close");
s = s.replace(closeAnchor, `      <Dialog open={manageOpen} onOpenChange={(next) => {
        if (!next) { setManageOpen(false); setTargetId(null); setConfirmName(""); }
      }}>
        <DialogContent className="max-h-[80vh] max-w-lg overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Manage scouts</DialogTitle>
            <DialogDescription>
              Deleting a scout removes their sign-in. Everything they scouted
              stays, attributed to a name that no longer resolves.
            </DialogDescription>
          </DialogHeader>

          <Input placeholder="Find a scout" value={manageSearch}
            onChange={(e) => setManageSearch(e.target.value)} />

          <div className="space-y-2">
            {(profiles ?? [])
              .filter((profile) =>
                manageSearch.trim() === "" ||
                profile.displayName.toLowerCase().includes(manageSearch.trim().toLowerCase()))
              .map((profile) => (
                <div key={profile._id} className="space-y-2 rounded-lg border p-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="min-w-0 flex-1 truncate text-sm font-medium">
                      {profile.displayName}
                    </span>
                    {profile.role === "admin" ? (
                      <Badge variant="secondary">Admin</Badge>
                    ) : (
                      <Button size="sm" variant="destructive"
                        onClick={() => {
                          setTargetId(targetId === profile._id ? null : profile._id);
                          setConfirmName("");
                        }}>
                        <Trash2 className="size-3" /> Delete
                      </Button>
                    )}
                  </div>

                  {targetId === profile._id ? (
                    <div className="space-y-2 rounded-md border border-dashed p-3">
                      <p className="text-destructive text-xs">
                        This removes their account permanently.
                      </p>
                      <Input placeholder={\`Type \${profile.displayName} to confirm\`}
                        value={confirmName}
                        onChange={(e) => setConfirmName(e.target.value)} />
                      <Button size="sm" variant="destructive"
                        disabled={busy || confirmName.trim() !== profile.displayName}
                        onClick={() => {
                          setBusy(true);
                          void deleteScout({ profileId: profile._id })
                            .then((r) => {
                              toast.success(\`\${r.displayName} deleted\`);
                              setTargetId(null);
                              setConfirmName("");
                            })
                            .catch((error: unknown) =>
                              toast.error("Could not delete", {
                                description:
                                  error instanceof Error ? error.message : String(error),
                              }))
                            .finally(() => setBusy(false));
                        }}>
                        Delete permanently
                      </Button>
                    </div>
                  ) : null}
                </div>
              ))}
          </div>
        </DialogContent>
      </Dialog>
${closeAnchor}`);

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
bun /tmp/ms.mjs
rm -f /tmp/ms.mjs
