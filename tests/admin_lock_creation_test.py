"""Deterministic create-vs-create races against the real shell lock library."""

import os
from pathlib import Path
import select
import stat
import subprocess
import tempfile
import unittest


LIBRARY = Path(__file__).resolve().parents[1] / "native/scripts/admin-lock.sh"
HARNESS = r'''
set -Eeuo pipefail
source "$1"
parent=$2
lock_path=${parent}/admin-mutation.lock
race=$3
expected_uid=$4
expected_gid=$5
callback() { printf 'CALLBACK\n'; }
creation_gate() {
  printf 'CREATION_READY\n'
  local response
  IFS= read -r response
  [[ $response == continue ]] || exit 98
}
if [[ $race == parent ]]; then
  mkdir() {
    # This function is reached only after the production absence check.
    [[ ! -e $parent && ! -L $parent ]] || exit 97
    creation_gate
    local rc=0
    command mkdir "$@" || rc=$?
    printf 'PROJECT_MKDIR_RC=%s\n' "$rc"
    return "$rc"
  }
elif [[ $race == lock ]]; then
  # Pause at the production O_EXCL redirection, after its absence check.
  # No production hook, source rewriting, sleeps or scheduler luck needed.
  set -T
  trap 'if [[ $BASH_COMMAND == '\'': > "${lock_path}"'\'' ]]; then creation_gate; fi' DEBUG
fi
admin_lock_run_at exclusive "$parent" "$lock_path" \
  "$expected_uid" "$expected_gid" 0.1 callback
'''


class LockCreationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="admin-lock-creation-")
        self.addCleanup(self.temporary.cleanup)
        self.area = Path(self.temporary.name)
        self.parent = self.area / "runtime"
        self.lock = self.parent / "admin-mutation.lock"
        self.uid, self.gid = os.getuid(), os.getgid()

    def command(self, race="none", uid=None, gid=None):
        return ["bash", "--noprofile", "--norc", "-c", HARNESS, "fixture",
                str(LIBRARY), str(self.parent), race,
                str(self.uid if uid is None else uid),
                str(self.gid if gid is None else gid)]

    @staticmethod
    def metadata(path):
        info = path.lstat()
        return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode)

    def winner(self, path, kind, directory):
        if kind == "missing":
            return
        if kind == "symlink":
            path.symlink_to(self.area / "never-create-this-target")
        elif kind == "wrong_type":
            if directory:
                path.write_bytes(b"winner: do not overwrite\n")
            else:
                path.mkdir(mode=0o700)
        elif directory:
            path.mkdir(mode=0o700)
        else:
            path.write_bytes(b"winner: do not truncate\n")
            path.chmod(0o600)
        if kind == "wrong_mode":
            path.chmod(0o750 if directory else 0o640)
        elif kind == "wrong_uid":
            os.chown(path, self.uid + 1, self.gid)
        elif kind == "wrong_gid":
            os.chown(path, self.uid, self.gid + 1)

    def race_case(self, race, kind, expected_rc):
        if race == "lock":
            self.parent.mkdir(mode=0o700)
        path = self.parent if race == "parent" else self.lock
        self.assertFalse(path.exists() or path.is_symlink())
        with subprocess.Popen(self.command(race), stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            try:
                ready, _, _ = select.select([process.stdout], [], [], 5)
                self.assertTrue(ready, "production creation boundary was not reached")
                self.assertEqual(process.stdout.readline(), "CREATION_READY\n")
                self.assertFalse(path.exists() or path.is_symlink())
                self.winner(path, kind, race == "parent")
                before = self.metadata(path) if kind != "missing" else None
                output, error = process.communicate("continue\n", timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertEqual(process.returncode, expected_rc, output + error)
        self.assertEqual(output.count("CALLBACK\n"), int(expected_rc == 0))
        if race == "parent" and kind != "missing":
            # The real mkdir ran against the concurrent winner and lost.
            self.assertIn("PROJECT_MKDIR_RC=1\n", output)
        if before is not None:
            self.assertEqual(self.metadata(path), before, "winner metadata changed")
        if race == "parent" and expected_rc:
            self.assertFalse(self.lock.exists())
        if race == "lock" and kind in ("valid", "wrong_mode", "wrong_uid", "wrong_gid"):
            self.assertEqual(self.lock.read_bytes(), b"winner: do not truncate\n")
        self.assertFalse((self.area / "never-create-this-target").exists())
        if expected_rc == 0:
            self.assertEqual(self.metadata(self.parent)[2:],
                             (self.uid, self.gid, stat.S_IFDIR | 0o700))
            self.assertEqual(self.metadata(self.lock)[2:],
                             (self.uid, self.gid, stat.S_IFREG | 0o600))

    def test_parent_correct_concurrent_creator_is_revalidated(self):
        self.race_case("parent", "valid", 0)

    def test_parent_wrong_mode_is_rejected_without_repair(self):
        self.race_case("parent", "wrong_mode", 73)

    def test_parent_symlink_winner_is_rejected(self):
        self.race_case("parent", "symlink", 73)

    def test_parent_non_directory_winner_is_rejected(self):
        self.race_case("parent", "wrong_type", 73)

    @unittest.skipUnless(os.geteuid() == 0, "real chown fixture requires local root")
    def test_parent_wrong_owner_winner_is_rejected(self):
        self.race_case("parent", "wrong_uid", 73)

    @unittest.skipUnless(os.geteuid() == 0, "real chown fixture requires local root")
    def test_parent_wrong_group_winner_is_rejected(self):
        self.race_case("parent", "wrong_gid", 73)

    def test_lock_correct_concurrent_creator_is_revalidated(self):
        self.race_case("lock", "valid", 0)

    def test_lock_wrong_mode_winner_is_rejected_without_repair(self):
        self.race_case("lock", "wrong_mode", 73)

    def test_lock_symlink_winner_is_rejected_without_following(self):
        self.race_case("lock", "symlink", 73)

    def test_lock_directory_winner_is_rejected(self):
        self.race_case("lock", "wrong_type", 73)

    @unittest.skipUnless(os.geteuid() == 0, "real chown fixture requires local root")
    def test_lock_wrong_owner_winner_is_rejected(self):
        self.race_case("lock", "wrong_uid", 73)

    @unittest.skipUnless(os.geteuid() == 0, "real chown fixture requires local root")
    def test_lock_wrong_group_winner_is_rejected(self):
        self.race_case("lock", "wrong_gid", 73)

    def test_existing_valid_parent_and_lock_keep_same_inode_and_bytes(self):
        self.parent.mkdir(mode=0o700)
        self.winner(self.lock, "valid", False)
        before = self.metadata(self.lock)
        for _ in range(2):
            result = subprocess.run(self.command(), capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "CALLBACK\n")
            self.assertEqual(self.metadata(self.lock), before)
            self.assertEqual(self.lock.read_bytes(), b"winner: do not truncate\n")

    def test_creation_failure_without_safe_final_parent_is_rejected(self):
        self.parent = self.area / "missing-ancestor" / "runtime"
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 73)
        self.assertNotIn("CALLBACK", result.stdout)
        self.assertFalse(self.parent.exists())


if __name__ == "__main__":
    unittest.main()
