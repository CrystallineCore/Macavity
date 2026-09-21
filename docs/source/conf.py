import pathlib
import re

# =============================================================================
# Project Information
# =============================================================================

project = "macavity"
author = "Sivaprasad Murali"
copyright = "2026, Sivaprasad Murali"

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _extension_version() -> str:
    """Read default_version from macavity.control, the single source of truth."""
    try:
        text = (ROOT / "macavity.control").read_text()
        match = re.search(r"^default_version\s*=\s*'([^']+)'", text, re.MULTILINE)
        if match:
            return match.group(1)
    except OSError:
        pass
    return "0.2.0"


# Exact release and documentation series.
release = _extension_version()
version = ".".join(release.split(".")[:2])

# =============================================================================
# General Configuration
# =============================================================================

extensions = [
    "myst_parser",
    "sphinx_sitemap",
]

templates_path = ["_templates"]

exclude_patterns = [
    "_build",
    "Thumbs.db",
    ".DS_Store",
]

# =============================================================================
# Source Files
# =============================================================================

source_suffix = {
    ".rst": "restructuredtext",
    ".md": "markdown",
}

master_doc = "index"

language = "en"

# =============================================================================
# MyST Markdown
# =============================================================================

myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "smartquotes",
    "tasklist",
    "attrs_inline",
    "attrs_block",
]

myst_heading_anchors = 3

# Most code blocks are SQL; the PostgreSQL lexer understands $$ bodies.
highlight_language = "postgresql"

# =============================================================================
# HTML Output
# =============================================================================

html_theme = "sphinx_rtd_theme"

html_static_path = ["_static"]

# Copied verbatim to the site root, next to sitemap.xml.
html_extra_path = ["robots.txt"]

html_title = (
    f"Macavity {release} Documentation - Deterministic Fault Injection for PostgreSQL"
)

html_short_title = "macavity Docs"

html_favicon = "_static/favicon.ico"
html_logo = "_static/logo.png"

html_theme_options = {
    "collapse_navigation": False,
    "sticky_navigation": True,
    "navigation_depth": 4,
    "style_nav_header_background": "#2C3E50",
}

html_context = {
    "display_github": True,
    "github_user": "crystallinecore",
    "github_repo": "macavity",
    "github_version": "main",
    "conf_py_path": "/docs/source/",
}

pygments_style = "sphinx"

# =============================================================================
# Canonical URL
# =============================================================================

html_baseurl = "https://macavity.readthedocs.io/en/latest/"

# =============================================================================
# SEO Metadata
# =============================================================================
#
# Page-level <meta>, Open Graph, Twitter and JSON-LD tags are emitted by
# _templates/layout.html; keep the two in sync.

SEO_DESCRIPTION = (
    "Macavity is a PostgreSQL extension for deterministic, session-local "
    "fault injection: arm an error, a delay or a backend crash at executor "
    "start, executor end, commit or abort, and have it fire on exactly the "
    "Nth hit. For development and test clusters."
)

SEO_KEYWORDS = (
    "macavity, PostgreSQL fault injection, PostgreSQL extension, "
    "PostgreSQL testing, error injection, crash testing, crash recovery "
    "testing, chaos engineering PostgreSQL, deterministic testing, "
    "PostgreSQL hooks, ExecutorStart_hook, ExecutorEnd_hook, "
    "RegisterXactCallback, commit failure testing, retry logic testing, "
    "statement_timeout testing, PGXN"
)

html_context.update(
    {
        "seo_description": SEO_DESCRIPTION,
        "seo_keywords": SEO_KEYWORDS,
        "seo_image": html_baseurl + "_static/logo.png",
    }
)

# =============================================================================
# Sitemap
# =============================================================================

sitemap_url_scheme = "{link}"

# =============================================================================
# Documentation Behavior
# =============================================================================

nitpicky = False

html_show_sourcelink = True
html_show_sphinx = False
html_show_copyright = True
