#!/usr/bin/env python3
"""Generate a combined ODP changelog from local component git repos.

Given a target ODP version (for example 3.4.3.0, 3.4.3.0-1012, or 3.3.6.6-1007),
this script:

1. Treats a trailing -<digits> suffix as a compile build number of the base
   release (3.4.3.0-1012 is the same release as 3.4.3.0).
2. Picks the 3.4.3 or 3.3.6 version line and the components that line supports.
3. Looks up each component's git repo and dedicated nightly/rel branch.
4. Fetches that branch from origin, then finds the markup/marker commit
   (release-specific version bump, Ambari overrides, or --marker) and lists
   commit subjects from that marker through the latest commit.
5. Writes one file with components in alphabetical order.

Example::

    python3 generate_odp_changelog.py 3.4.3.0-1012
    python3 generate_odp_changelog.py ODP-3.3.6.6
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional

LOGGER = logging.getLogger("odp_changelog")


LINE_343 = "3.4.3"
LINE_336 = "3.3.6"

DEFAULT_REPOS_DIR = os.path.dirname(os.path.abspath(__file__))


@dataclass(frozen=True)
class LineSpec:
    component_version: Optional[str]
    branch: Optional[str]


@dataclass(frozen=True)
class Component:
    service: str
    heading: str
    repo: Optional[str]
    line_343: LineSpec
    line_336: LineSpec

    def spec_for(self, line: str) -> LineSpec:
        return self.line_343 if line == LINE_343 else self.line_336


def _s(version: Optional[str], branch: Optional[str]) -> LineSpec:
    return LineSpec(version, branch)


def _c(
    service: str,
    repo: Optional[str],
    line_343: LineSpec,
    line_336: LineSpec,
    heading: Optional[str] = None,
) -> Component:
    return Component(service, heading or (repo or service.lower()), repo, line_343, line_336)


# Service table: a dash in repo or branch means the component is not collected.
COMPONENTS: list[Component] = [
    _c("Airflow (mpack)", "airflow", _s("3.2.2", "nightly/ODP-3.4.3.0"), _s("2.8.3", "nightly/ODP-3.3.6.6")),
    _c("Ambari", "odp-ambari", _s("3.0.1.0", "rel/ODP-AMBARI-3.0.1.0-1"), _s("3.0.0.2-1", "rel/ODP-AMBARI-3.0.1.1"), "ambari"),
    _c("Celeborn (mpack)", "celeborn", _s("0.6.3", "nightly/ODP-3.4.3.0"), _s("0.6.2", "nightly/ODP-3.3.6.6")),
    _c("ClickHouse (mpack)", "clickhouse", _s("26.3.15.1", "nightly/ODP-3.4.3.0"), _s("25.5.4.38", "nightly/ODP-3.3.6.6")),
    _c("Cruise Control + Kafka 2", "cruise-control", _s(None, None), _s("2.5.84", "nightly/ODP-3.3.6.6")),
    _c("Cruise Control + Kafka 3 (mpack)", "cruise-control3", _s("2.5.143", "nightly/ODP-3.4.3.0"), _s("2.5.137", "nightly/ODP-3.3.6.6")),
    _c("Cruise Control4 + Kafka 4", "cruise-control3", _s("2.5.146", "nightly/ODP-2.5.146.3.4.3.0"), _s("2.5.146", "nightly/ODP-2.5.146.3.3.6.6"), "cruise-control4"),
    _c("Druid", "druid", _s(None, None), _s("29.0.1", "nightly/ODP-3.3.6.6")),
    _c("Flink", "flink", _s("2.2.1", "nightly/ODP-3.4.3.0"), _s("1.19.1", "nightly/ODP-3.3.6.6")),
    _c("Hadoop", "hadoop", _s("3.4.3", "nightly/ODP-3.4.3.0"), _s("3.3.6", "nightly/ODP-3.3.6.6")),
    _c("HBase", "hbase", _s("2.6.4", "nightly/ODP-3.4.3.0"), _s("2.6.2", "nightly/ODP-3.3.6.6")),
    _c("Hive", "hive", _s("4.1.0", "nightly/ODP-3.4.3.0"), _s("4.1.0", "nightly/ODP-3.3.6.6")),
    _c("Httpfs (mpack)", None, _s("3.4.3", None), _s("2.7.1", None), "httpfs"),  # namesake only; no changelog
    _c("Hue (mpack)", "hue", _s("4.11.0", "nightly/ODP-3.4.3.0"), _s("4.11.0", "nightly/ODP-3.3.6.6")),
    _c("Impala (mpack)", "impala", _s("4.5.0", "nightly/ODP-3.4.3.0"), _s("4.4.1", "nightly/ODP-3.3.6.6")),
    _c("Infra Solr", "odp-ambari-infra", _s("3.0.1.0", "rel/ODP-AMBARI-3.0.1.0-1"), _s("3.0.1.1", "rel/ODP-AMBARI-3.0.1.1"), "infra-solr"),
    _c("Isilon (mpack)", None, _s(None, None), _s("1.0.3", None), "isilon"),
    _c("Jupyterhub", "jupyterhub", _s("5.5.0", "nightly/ODP-3.4.3.0"), _s("5.2.1", "nightly/ODP-3.3.6.6")),
    _c("Kafka 2", "kafka", _s(None, None), _s("2.8.2", "nightly/ODP-3.3.6.6"), "kafka2"),
    _c("Kafka 3 (mpack)", "kafka3", _s("3.9.2", "nightly/ODP-3.4.3.0"), _s("3.7.2", "nightly/ODP-3.3.6.6")),
    _c("Kafka 4", "kafka3", _s("4.3.0", "nightly/ODP-4.3.1.3.4.3.0"), _s("4.3.0", "nightly/ODP-4.3.0.3.3.6.6"), "kafka4"),
    _c("Knox", "knox", _s("2.1.0", "nightly/ODP-3.4.3.0"), _s("2.0.0", "nightly/ODP-3.3.6.6")),
    _c("Kudu", "kudu", _s("1.18.0", "nightly/ODP-3.4.3.0"), _s("1.17.0", "nightly/ODP-3.3.6.6")),
    _c("Livy", "livy", _s("0.9.0", "nightly/ODP-3.4.3.0"), _s("0.8.0", "nightly/ODP-3.3.6.6")),
    _c("MLflow", "mlflow", _s("3.16.0", "nightly/ODP-3.4.3.0"), _s("3.1.0", "nightly/ODP-3.3.6.6")),
    _c("NiFi (mpack)", "nifi", _s(None, None), _s("1.28.1", "nightly/ODP-3.3.6.6")),
    _c("NiFi 2 (mpack)", "nifi", _s("2.8.0", "nightly/ODP-3.4.3.0"), _s("2.7.2", "nightly/ODP-2.7.2.3.3.6.6"), "nifi2"),
    _c("NiFi Registry (mpack)", None, _s(None, None), _s("1.28.1", None), "nifi-registry"),
    _c("NiFi Registry 2 (mpack)", None, _s("2.8.0", None), _s("2.7.2", None), "nifi-registry2"),  # lives in nifi; skip changelog
    _c("Oozie", "oozie", _s(None, None), _s("5.2.1", "nightly/ODP-3.3.6.6")),
    _c("Ozone (mpack)", "ozone", _s("2.2.1", "nightly/ODP-3.4.3.0"), _s("2.1.0", "nightly/ODP-3.3.6.6")),
    _c("Phoenix", "phoenix", _s("5.3.1", "nightly/ODP-3.4.3.0"), _s("5.2.1", "nightly/ODP-3.3.6.6")),
    _c("Pinot", "pinot", _s("1.5.0", "nightly/ODP-3.4.3.0"), _s("1.4.0", "nightly/ODP-3.3.6.6")),
    _c("Ranger", "ranger", _s("2.9.0", "nightly/ODP-3.4.3.0"), _s("2.5.0", "nightly/ODP-3.3.6.6")),
    _c("Schema Registry (mpack)", "registry", _s("1.0.0", "nightly/ODP-3.4.3.0"), _s("1.0.0", "nightly/ODP-3.3.6.6")),
    _c("SeaTunnel", "seatunnel", _s("2.3.13", "nightly/ODP-3.4.3.0"), _s("2.3.13", "nightly/ODP-3.3.6.6")),
    _c("spark2", "spark", _s(None, None), _s("2.4.8", "nightly/ODP-3.3.6.6"), "spark2"),
    _c("Spark3 (mpack)", "spark3", _s("3.5.8", "nightly/ODP-3.4.3.0"), _s("3.5.5", "nightly/ODP-3.3.6.6")),
    _c("Spark3_3_5_1 (mpack)", "spark3", _s(None, None), _s("3.5.1", "nightly/ODP-3.5.1.3.3.6.6"), "spark3_3_5_1"),
    _c("Spark3_3_3_3_3 (mpack)", "spark3", _s(None, None), _s("3.3.3", "nightly/ODP-3.3.3.3.3.6.6"), "spark3_3_3_3_3"),
    _c("Spark 4 (mpack)", "spark3", _s("4.1.2", "nightly/ODP-4.1.2.3.4.3.0"), _s("4.1.1", "nightly/ODP-4.1.1.3.3.6.6"), "spark4"),
    _c("Spark RAPIDS", "spark-rapids", _s("26.08", "nightly/ODP-3.4.3.0"), _s("26.02", "nightly/ODP-3.3.6.6")),
    _c("Spark3-warehouse-connector", "spark3-warehouse-connector", _s("1.0.0", "nightly/ODP-3.4.3.0"), _s("1.0.0", "nightly/ODP-3.3.6.6")),
    _c("Spark4-warehouse-connector", "spark3-warehouse-connector", _s("1.0.0", "nightly/ODP-4.1.2.3.4.3.0"), _s("1.0.0", "nightly/ODP-4.1.1.3.3.6.6"), "spark4-warehouse-connector"),
    _c("Sqoop", "sqoop", _s(None, None), _s("1.4.8", "nightly/ODP-3.3.6.6")),
    _c("Superset", "superset", _s("6.1.0", "nightly/ODP-3.4.3.0"), _s("6.0.0", "nightly/ODP-3.3.6.6")),
    _c("Tez", "tez", _s("0.10.5", "nightly/ODP-3.4.3.0"), _s("0.10.4", "nightly/ODP-3.3.6.6")),
    _c("Trino", "trino", _s("481", "nightly/ODP-3.4.3.0"), _s("472", "nightly/ODP-3.3.6.6")),
    _c("Trino Gateway", "trino-gateway", _s("19", "nightly/ODP-3.4.3.0"), _s("15", "nightly/ODP-3.3.6.6")),
    _c("Zeppelin", "zeppelin", _s(None, None), _s("0.12.0", "nightly/ODP-3.3.6.6")),
    _c("Zookeeper", "zookeeper", _s("3.8.6", "nightly/ODP-3.4.3.0"), _s("3.8.4", "nightly/ODP-3.3.6.6")),
]

# Markup/marker commit subjects that are not the usual ODP version bump.
# Keyed by (repo name, git branch).
MARKER_OVERRIDES: dict[tuple[str, str], str] = {
    ("odp-ambari", "rel/ODP-AMBARI-3.0.1.0-1"): "ODP-6879: Update Ambari version",
    ("odp-ambari", "rel/ODP-AMBARI-3.0.1.1"): "[Automated] Changed version from '3.0.1.0' to '3.0.1.1'",
    ("odp-ambari-infra", "rel/ODP-AMBARI-3.0.1.0-1"): "ODP-6879: Update Ambari version",
    ("odp-ambari-infra", "rel/ODP-AMBARI-3.0.1.1"): "[Automated] Changed version from '3.0.1.0' to '3.0.1.1'",
}


PR_SUFFIX = re.compile(r"\s*\(#\d+\)\s*$")
BUILD_NUMBER_SUFFIX = re.compile(r"-\d+$")


class GitError(RuntimeError):
    pass


def run_git(repo: str, args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        err = (result.stderr or result.stdout or "").strip() or f"git {' '.join(args)} failed"
        raise GitError(err)
    return result


def normalize_odp_version(raw: str) -> str:
    version = raw.strip()
    if version.upper().startswith("ODP-"):
        version = version[4:]
    if not version:
        raise ValueError("ODP version is empty")
    return version


def base_release_version(version: str) -> str:
    """Drop a trailing -<build> compile number (3.4.3.0-1012 -> 3.4.3.0)."""
    return BUILD_NUMBER_SUFFIX.sub("", version)


def detect_line(version: str) -> str:
    if version.startswith(f"{LINE_343}.") or version == LINE_343:
        return LINE_343
    if version.startswith(f"{LINE_336}.") or version == LINE_336:
        return LINE_336
    raise ValueError(
        f"Cannot map {version!r} to an ODP line. Expected a 3.4.3.x or 3.3.6.x version "
        "(for example 3.4.3.0, 3.3.6.6, 3.3.6.5-1, 3.3.6.501-1012)."
    )


def supported_components(line: str) -> list[Component]:
    items = [c for c in COMPONENTS if c.spec_for(line).branch and c.repo]
    return sorted(items, key=lambda c: c.heading.lower())


def ref_exists(repo: str, ref: str) -> bool:
    result = run_git(repo, ["rev-parse", "--verify", "--quiet", ref], check=False)
    return result.returncode == 0 and bool(result.stdout.strip())


def resolve_branch_ref(repo: str, branch: str) -> Optional[str]:
    for candidate in (f"refs/remotes/origin/{branch}", f"origin/{branch}", f"refs/heads/{branch}", branch):
        if ref_exists(repo, candidate):
            return candidate
    return None


def fetch_branch(repo: str, branch: str) -> None:
    LOGGER.info("Fetching origin %s in %s", branch, repo)
    result = run_git(repo, ["fetch", "origin", branch], check=False)
    if result.returncode != 0:
        err = (result.stderr or result.stdout or "git fetch failed").strip()
        LOGGER.warning("Fetch failed for %s (%s): %s", repo, branch, err)
        run_git(repo, ["fetch", "origin", f"{branch}:{branch}"], check=False)


def checkout_branch(repo: str, branch: str) -> None:
    if ref_exists(repo, f"refs/heads/{branch}"):
        run_git(repo, ["checkout", branch])
        if ref_exists(repo, f"refs/remotes/origin/{branch}"):
            run_git(repo, ["merge", "--ff-only", f"origin/{branch}"], check=False)
        return
    if ref_exists(repo, f"refs/remotes/origin/{branch}"):
        run_git(repo, ["checkout", "-B", branch, f"origin/{branch}"])
        return
    raise GitError(f"branch {branch} not found")


def grep_commits(repo: str, ref: str, pattern: str, fixed: bool = False) -> list[tuple[str, str]]:
    args = ["log", ref, "-n", "200"]
    if fixed:
        args.append("--fixed-strings")
    args.extend(["--grep", pattern, "--format=%H%x09%s"])
    result = run_git(repo, args, check=False)
    commits: list[tuple[str, str]] = []
    if result.returncode != 0:
        return commits
    for line in result.stdout.splitlines():
        sha, sep, subject = line.partition("\t")
        if sep:
            commits.append((sha, subject))
    return commits


def subject_matches_version_bump(subject: str, version: str) -> bool:
    """Match the markup that opens this base release.

    Examples:
      [Automated] Changed version from '3.4.3.0-1' to '3.4.3.0-SNAPSHOT'
      [Automated] Changed version from '3.3.6.5-SNAPSHOT' to '3.3.6.6-SNAPSHOT'
    """
    if "changed version" not in subject.lower():
        return False
    needles = (
        f"to '{version}-SNAPSHOT'",
        f'to "{version}-SNAPSHOT"',
        f"to {version}-SNAPSHOT",
        f"from '{version}-1' to '{version}-SNAPSHOT'",
    )
    return any(needle in subject for needle in needles)


def first_matching_commit(
    repo: str,
    ref: str,
    pattern: str,
    predicate=None,
    fixed: bool = True,
) -> tuple[Optional[str], Optional[str]]:
    commits = grep_commits(repo, ref, pattern, fixed=fixed)
    if not commits and fixed:
        commits = grep_commits(repo, ref, pattern, fixed=False)
    for sha, subject in commits:
        if predicate is None or predicate(subject):
            return sha, subject
    return None, None


def find_marker(
    repo: str,
    ref: str,
    version: str,
    extra: Optional[str],
    override: Optional[str] = None,
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """Return (hash, subject, matched_pattern)."""
    for pattern in (extra, override):
        if not pattern:
            continue
        sha, subject = first_matching_commit(repo, ref, pattern)
        if sha:
            return sha, subject, pattern

    exact_ga = f"[Automated] Changed version from '{version}-1' to '{version}-SNAPSHOT'"
    sha, subject = first_matching_commit(repo, ref, exact_ga)
    if sha:
        return sha, subject, exact_ga

    sha, subject = first_matching_commit(
        repo,
        ref,
        "[Automated] Changed version from",
        predicate=lambda s: subject_matches_version_bump(s, version),
    )
    if sha:
        return sha, subject, f"to '{version}-SNAPSHOT'"

    sha, subject = first_matching_commit(
        repo,
        ref,
        "Changed version from",
        predicate=lambda s: subject_matches_version_bump(s, version),
    )
    if sha:
        return sha, subject, f"to '{version}-SNAPSHOT'"

    return None, None, None


def commit_subjects(repo: str, start: str, ref: str, include_marker: bool) -> list[str]:
    spec = f"{start}^..{ref}" if include_marker else f"{start}..{ref}"
    result = run_git(repo, ["log", spec, "--format=%s"])
    subjects = []
    for raw in result.stdout.splitlines():
        text = PR_SUFFIX.sub("", raw).rstrip()
        if text:
            subjects.append(text)
    return subjects


@dataclass
class ComponentResult:
    component: Component
    heading: str
    status: str
    detail: str
    subjects: list[str]
    branch: Optional[str] = None
    marker_subject: Optional[str] = None


def collect_component(
    component: Component,
    line: str,
    version: str,
    repos_dir: str,
    checkout: bool,
    extra_marker: Optional[str],
    include_marker: bool,
) -> ComponentResult:
    heading = component.heading
    spec = component.spec_for(line)
    repo_name = component.repo
    branch = spec.branch

    if not repo_name or not branch:
        return ComponentResult(component, heading, "skipped", "no git repo or branch for this ODP line", [])

    repo_path = os.path.join(repos_dir, repo_name)
    if not os.path.isdir(os.path.join(repo_path, ".git")) and not os.path.isdir(repo_path):
        return ComponentResult(component, heading, "missing-repo", f"repo directory not found: {repo_path}", [], branch)

    if not os.path.isdir(os.path.join(repo_path, ".git")):
        return ComponentResult(component, heading, "missing-repo", f"not a git repo: {repo_path}", [], branch)

    fetch_branch(repo_path, branch)

    ref = resolve_branch_ref(repo_path, branch)
    if not ref:
        return ComponentResult(
            component,
            heading,
            "missing-branch",
            f"branch {branch} not found locally or on origin",
            [],
            branch,
        )

    if checkout:
        try:
            checkout_branch(repo_path, branch)
            ref = "HEAD"
        except GitError as exc:
            return ComponentResult(component, heading, "checkout-failed", str(exc), [], branch)

    override = MARKER_OVERRIDES.get((repo_name, branch))
    marker_sha, marker_subject, matched = find_marker(
        repo_path, ref, version, extra_marker, override=override
    )
    if not marker_sha:
        detail = f"no marker commit matching ODP version {version} on {branch}"
        LOGGER.warning(
            "Markup message not found for %s (repo=%s, branch=%s, version=%s)",
            heading,
            repo_name,
            branch,
            version,
        )
        return ComponentResult(component, heading, "missing-marker", detail, [], branch)

    try:
        subjects = commit_subjects(repo_path, marker_sha, ref, include_marker)
    except GitError as exc:
        return ComponentResult(component, heading, "git-error", str(exc), [], branch, marker_subject)

    detail = f"marker: {marker_subject} (matched {matched!r})"
    if not subjects:
        LOGGER.warning(
            "No git log changes for %s (repo=%s, branch=%s) after marker: %s",
            heading,
            repo_name,
            branch,
            marker_subject,
        )
        return ComponentResult(component, heading, "empty", detail, subjects, branch, marker_subject)
    return ComponentResult(component, heading, "ok", detail, subjects, branch, marker_subject)


def render_changelog(odp_label: str, results: list[ComponentResult]) -> str:
    lines = [f"CHANGELOG {odp_label}", ""]
    for result in results:
        if result.status in {"skipped"}:
            continue
        lines.append(result.heading)
        if result.status == "ok":
            lines.extend(result.subjects)
        elif result.status == "empty":
            lines.append("No git log changes after the markup message.")
        elif result.status == "missing-marker":
            lines.append("Markup message was not found.")
        else:
            lines.append(f"No commits ({result.detail})" if result.detail else "No commits")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_summary(results: list[ComponentResult]) -> str:
    groups = {
        "ok": "Components with changelog",
        "empty": "Components with marker found but no later commits",
        "missing-marker": "Missing changelog (marker commit not found)",
        "missing-branch": "Missing changelog (git branch not found)",
        "missing-repo": "Missing changelog (local git repo not found)",
        "checkout-failed": "Missing changelog (checkout failed)",
        "git-error": "Missing changelog (git error)",
        "skipped": "Skipped (no repo/branch on this ODP line)",
    }
    lines = ["", "============================================================", "SUMMARY", "============================================================", ""]
    by_status: dict[str, list[ComponentResult]] = {}
    for result in results:
        by_status.setdefault(result.status, []).append(result)

    for status, title in groups.items():
        items = by_status.get(status, [])
        lines.append(f"{title}:")
        if not items:
            lines.append("  (none)")
        else:
            for item in items:
                extra = f" [{item.branch}]" if item.branch else ""
                lines.append(f"  - {item.heading}{extra}: {item.detail}" if item.detail else f"  - {item.heading}{extra}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect ODP component changelogs from marker commit to latest on each line's git branch."
    )
    parser.add_argument(
        "version",
        help="Target ODP version, with or without ODP- prefix and optional -<build> (e.g. 3.4.3.0, 3.4.3.0-1012, ODP-3.3.6.6-1007).",
    )
    parser.add_argument(
        "--repos-dir",
        default=DEFAULT_REPOS_DIR,
        help=f"Directory that contains component git clones (default: {DEFAULT_REPOS_DIR}).",
    )
    parser.add_argument(
        "--output",
        help="Output path. Default: Changelog-ODP-<version>.txt in --repos-dir.",
    )
    parser.add_argument(
        "--checkout",
        action="store_true",
        help="Check out each component branch in the working tree (off by default).",
    )
    parser.add_argument(
        "--marker",
        help="Extra git-log --grep pattern to try first when locating the marker commit.",
    )
    parser.add_argument(
        "--include-marker",
        action="store_true",
        help="Include the marker commit itself in the changelog (default: commits after the marker only).",
    )
    parser.add_argument(
        "--no-summary",
        action="store_true",
        help="Do not append the missing-marker / skipped-component summary.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
        stream=sys.stderr,
    )
    args = parse_args(argv)
    try:
        input_version = normalize_odp_version(args.version)
        version = base_release_version(input_version)
        line = detect_line(version)
    except ValueError as exc:
        LOGGER.error("%s", exc)
        return 2

    odp_label = f"ODP-{input_version}"
    repos_dir = os.path.abspath(args.repos_dir)
    output = args.output or os.path.join(repos_dir, f"Changelog-{odp_label}.txt")

    print(f"ODP version: {odp_label}")
    if input_version != version:
        print(f"Base release: {version} (build suffix ignored for markup matching)")
    print(f"Version line: {line}")
    print(f"Repos dir: {repos_dir}")
    print(f"Output: {output}")

    results: list[ComponentResult] = []
    for component in supported_components(line):
        print(f"- {component.heading} ({component.repo} @ {component.spec_for(line).branch})")
        try:
            result = collect_component(
                component,
                line,
                version,
                repos_dir,
                checkout=args.checkout,
                extra_marker=args.marker,
                include_marker=args.include_marker,
            )
        except GitError as exc:
            result = ComponentResult(
                component,
                component.heading,
                "git-error",
                str(exc),
                [],
                component.spec_for(line).branch,
            )
        print(f"    {result.status}: {result.detail} ({len(result.subjects)} commits)")
        results.append(result)

    # Also record skipped table rows (no branch) in the summary only.
    for component in COMPONENTS:
        if component.spec_for(line).branch and component.repo:
            continue
        if component.spec_for(line).component_version or component.spec_for(line).branch:
            results.append(
                ComponentResult(
                    component,
                    component.heading,
                    "skipped",
                    "no git repo or branch listed for this ODP line",
                    [],
                )
            )

    body = render_changelog(odp_label, [r for r in results if r.status != "skipped"])
    if not args.no_summary:
        body += render_summary(results)

    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(body)

    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
