from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

import yaml
from pglast import parse_sql


ROOT = Path(__file__).resolve().parents[1]
IGNORED_PATH_PARTS = {".git", ".venv", "node_modules"}


def is_project_source(path: Path) -> bool:
    return not any(part in IGNORED_PATH_PARTS for part in path.relative_to(ROOT).parts)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def validate_yaml() -> tuple[int, dict]:
    yaml_files = sorted(
        path
        for path in [*ROOT.rglob("*.yml"), *ROOT.rglob("*.yaml")]
        if is_project_source(path)
    )
    documents: dict[Path, object] = {}
    for path in yaml_files:
        documents[path] = yaml.safe_load(path.read_text(encoding="utf-8"))
    return len(yaml_files), documents


def validate_openapi(spec: dict) -> tuple[int, int]:
    operation_ids: list[str] = []
    methods = {"get", "post", "put", "patch", "delete", "options", "head", "trace"}
    for path_item in spec.get("paths", {}).values():
        for method, operation in path_item.items():
            if method.lower() in methods:
                operation_id = operation.get("operationId")
                if not operation_id:
                    raise AssertionError(f"OpenAPI operationId missing: {method}")
                operation_ids.append(operation_id)
    if len(operation_ids) != len(set(operation_ids)):
        raise AssertionError("OpenAPI operationId values must be unique")

    source = read("api/openapi.yaml")
    refs = re.findall(r"\$ref:\s*['\"]?#/components/([^/]+)/([^'\"\s]+)", source)
    for section, name in refs:
        if name not in spec["components"][section]:
            raise AssertionError(f"Missing OpenAPI reference: {section}/{name}")
    return len(operation_ids), len(refs)


def validate_markdown() -> int:
    markdown_files = sorted(path for path in ROOT.rglob("*.md") if is_project_source(path))
    unbalanced: list[str] = []
    broken_links: list[str] = []
    link_pattern = re.compile(r"\[[^\]]+\]\((?!https?://|mailto:|#)([^)]+)\)")
    for path in markdown_files:
        source = path.read_text(encoding="utf-8")
        fences = sum(1 for line in source.splitlines() if line.startswith("```"))
        if fences % 2:
            unbalanced.append(str(path.relative_to(ROOT)))
        for target in link_pattern.findall(source):
            clean = unquote(target.split("#", 1)[0]).strip("<>")
            if clean and not (path.parent / clean).resolve().exists():
                broken_links.append(f"{path.relative_to(ROOT)} -> {target}")
    if unbalanced:
        raise AssertionError(f"Unbalanced Markdown fences: {unbalanced}")
    if broken_links:
        raise AssertionError(f"Broken relative Markdown links: {broken_links}")
    return len(markdown_files)


def ids(pattern: str, relative: str) -> set[str]:
    return set(re.findall(pattern, read(relative)))


def validate_traceability() -> tuple[int, int, int]:
    requirement_pattern = r"\b(?:FR|NFR)-[BA]-\d{3}\b"
    test_pattern = r"\bTC-[FN]-[BA]-\d{3}\b"
    use_case_pattern = r"\bUC-[BA]-\d{3}\b"

    requirements = ids(requirement_pattern, "docs/01_요구사항_명세서.md")
    traced_requirements = ids(requirement_pattern, "docs/07_요구사항_추적성_매트릭스.md")
    if requirements != traced_requirements:
        raise AssertionError(
            f"Requirement mismatch: spec-only={requirements - traced_requirements}, "
            f"trace-only={traced_requirements - requirements}"
        )

    planned_tests = ids(test_pattern, "docs/08_테스트_계획서.md")
    result_tests = ids(test_pattern, "docs/09_테스트_결과서_템플릿.md")
    traced_tests = ids(test_pattern, "docs/07_요구사항_추적성_매트릭스.md")
    if not planned_tests == result_tests == traced_tests:
        raise AssertionError(
            f"Test ID mismatch: plan={len(planned_tests)}, result={len(result_tests)}, "
            f"trace={len(traced_tests)}"
        )

    use_cases = ids(use_case_pattern, "docs/02_사용자_스토리_및_유스케이스.md")
    traced_use_cases = ids(use_case_pattern, "docs/07_요구사항_추적성_매트릭스.md")
    if use_cases != traced_use_cases:
        raise AssertionError(
            f"Use-case mismatch: doc-only={use_cases - traced_use_cases}, "
            f"trace-only={traced_use_cases - use_cases}"
        )
    return len(requirements), len(use_cases), len(planned_tests)


def validate_sql() -> int:
    return len(parse_sql(read("database/schema.sql")))


def main() -> int:
    yaml_count, yaml_documents = validate_yaml()
    openapi_path = ROOT / "api/openapi.yaml"
    operation_count, ref_count = validate_openapi(yaml_documents[openapi_path])
    markdown_count = validate_markdown()
    requirement_count, use_case_count, test_count = validate_traceability()
    statement_count = validate_sql()
    print(
        "VALID "
        f"yaml={yaml_count} markdown={markdown_count} "
        f"openapi_operations={operation_count} openapi_refs={ref_count} "
        f"sql_statements={statement_count} requirements={requirement_count} "
        f"use_cases={use_case_count} test_cases={test_count}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"INVALID {exc}", file=sys.stderr)
        raise
