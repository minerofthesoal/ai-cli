# ============================================================================
# MODULE: 31-papers.sh
# Research paper scraper (arXiv, PMC, bioRxiv, CORE)
# Source lines 11193-11472 of main-v2.7.3
# ============================================================================

cmd_papers() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    search)
      [[ -z "${*}" ]] && { err "Usage: ai papers search <query> [--source arxiv|pmc|core|openalex|all]"; return 1; }
      local query="" source="all"
      while [[ $# -gt 0 ]]; do
        case "$1" in --source|-s) source="$2"; shift 2 ;; *) query="$query $1"; shift ;; esac
      done
      query="${query# }"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      "$PYTHON" - "$query" "$source" "$PAPERS_DIR" <<'PYEOF'
import sys, os, json, urllib.request, urllib.parse, time

query = sys.argv[1]
source = sys.argv[2].lower()
papers_dir = sys.argv[3]
os.makedirs(papers_dir, exist_ok=True)
results = []

def fetch(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {'User-Agent': 'AI-CLI/2.5 (research)'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read().decode('utf-8', errors='replace')
    except Exception as e:
        return None

# arXiv
if source in ('all', 'arxiv'):
    q = urllib.parse.quote(query)
    url = f"https://export.arxiv.org/api/query?search_query=all:{q}&start=0&max_results=5"
    data = fetch(url)
    if data:
        import xml.etree.ElementTree as ET
        ns = {'a': 'http://www.w3.org/2005/Atom'}
        try:
            root = ET.fromstring(data)
            for entry in root.findall('a:entry', ns)[:5]:
                title = (entry.find('a:title', ns).text or '').strip().replace('\n',' ')
                authors = [a.find('a:name', ns).text for a in entry.findall('a:author', ns)]
                year = (entry.find('a:published', ns).text or '')[:4]
                arxiv_id = (entry.find('a:id', ns).text or '').split('/')[-1]
                abstract = (entry.find('a:summary', ns).text or '').strip()[:300]
                results.append({'source': 'arXiv', 'id': arxiv_id, 'title': title,
                    'authors': authors, 'year': year, 'abstract': abstract,
                    'url': f"https://arxiv.org/abs/{arxiv_id}"})
        except: pass

# PubMed Central (open access)
if source in ('all', 'pmc'):
    q = urllib.parse.quote(query)
    url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pmc&term={q}&retmax=5&retmode=json&tool=ai-cli&email=ai-cli@example.com"
    data = fetch(url)
    if data:
        try:
            ids = json.loads(data).get('esearchresult', {}).get('idlist', [])[:5]
            for pmcid in ids:
                info_url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pmc&id={pmcid}&retmode=json"
                info_data = fetch(info_url)
                if info_data:
                    d = json.loads(info_data).get('result', {}).get(pmcid, {})
                    title = d.get('title', 'Unknown')
                    authors = [a.get('name','') for a in d.get('authors', [])[:3]]
                    year = str(d.get('pubdate', ''))[:4]
                    results.append({'source': 'PMC', 'id': pmcid, 'title': title,
                        'authors': authors, 'year': year, 'abstract': '',
                        'url': f"https://www.ncbi.nlm.nih.gov/pmc/articles/PMC{pmcid}/"})
                time.sleep(0.34)  # NCBI rate limit
        except: pass

# CORE (open access research)
if source in ('all', 'core'):
    q = urllib.parse.quote(query)
    url = f"https://api.core.ac.uk/v3/search/works?q={q}&limit=5"
    data = fetch(url)
    if data:
        try:
            items = json.loads(data).get('results', [])[:5]
            for item in items:
                title = item.get('title', 'Unknown')
                authors = [a.get('name','') for a in item.get('authors', [])[:3]]
                year = str(item.get('yearPublished', ''))
                doi = item.get('doi', '')
                abstract = (item.get('abstract') or '')[:300]
                results.append({'source': 'CORE', 'id': doi or item.get('id',''),
                    'title': title, 'authors': authors, 'year': year,
                    'abstract': abstract, 'url': item.get('downloadUrl','') or item.get('sourceFulltextUrls',[''])[0]})
        except: pass

# OpenAlex (open access)
if source in ('all', 'openalex'):
    q = urllib.parse.quote(query)
    url = f"https://api.openalex.org/works?search={q}&filter=is_oa:true&per-page=5&mailto=ai-cli@example.com"
    data = fetch(url)
    if data:
        try:
            items = json.loads(data).get('results', [])[:5]
            for item in items:
                title = item.get('display_name', 'Unknown')
                authors = [a.get('author',{}).get('display_name','') for a in item.get('authorships',[])[:3]]
                year = str(item.get('publication_year',''))
                doi = item.get('doi','')
                abstract_inv = item.get('abstract_inverted_index')
                abstract = ''
                if abstract_inv:
                    words = sorted([(pos, w) for w, positions in abstract_inv.items() for pos in positions])
                    abstract = ' '.join(w for _,w in words[:60])
                results.append({'source': 'OpenAlex', 'id': doi,
                    'title': title, 'authors': authors, 'year': year,
                    'abstract': abstract[:300], 'url': item.get('primary_location',{}).get('landing_page_url','') or doi})
        except: pass

# Print results
print(f"\nFound {len(results)} papers:\n")
for i, p in enumerate(results, 1):
    print(f"[{i}] {p['title']}")
    print(f"    Authors: {', '.join(p['authors'][:3])}")
    print(f"    Year: {p['year']}  Source: {p['source']}  ID: {p['id']}")
    print(f"    URL: {p['url']}")
    if p['abstract']:
        print(f"    Abstract: {p['abstract'][:200]}...")
    print()

# Save results index
idx_file = os.path.join(papers_dir, 'search_results.json')
existing = []
if os.path.exists(idx_file):
    try: existing = json.load(open(idx_file))
    except: pass
existing.extend(results)
json.dump(existing, open(idx_file, 'w'), indent=2)
print(f"Results saved to {idx_file}")
print(f"Use: ai papers cite <number> [apa|mla|bibtex|ieee|chicago]")
PYEOF
      ;;

    download)
      local id="${1:?paper ID or URL required}"; shift
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      "$PYTHON" - "$id" "$PAPERS_DIR" <<'PYEOF'
import sys, os, urllib.request, json, re

paper_id = sys.argv[1]
papers_dir = sys.argv[2]
os.makedirs(papers_dir, exist_ok=True)

def fetch_url(url, out_file):
    req = urllib.request.Request(url, headers={'User-Agent': 'AI-CLI/2.5'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r, open(out_file, 'wb') as f:
            f.write(r.read())
        return True
    except Exception as e:
        print(f"Error: {e}")
        return False

# Detect paper type
if 'arxiv.org' in paper_id or re.match(r'^\d{4}\.\d+', paper_id):
    arxiv_id = re.search(r'(\d{4}\.\d+)', paper_id)
    if arxiv_id:
        arxiv_id = arxiv_id.group(1)
        pdf_url = f"https://arxiv.org/pdf/{arxiv_id}.pdf"
        out = os.path.join(papers_dir, f"arxiv_{arxiv_id}.pdf")
        if fetch_url(pdf_url, out):
            print(f"Downloaded: {out}")
elif 'pmc' in paper_id.lower() or paper_id.isdigit():
    pmcid = re.sub(r'[^0-9]', '', paper_id)
    pdf_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/PMC{pmcid}/pdf/"
    out = os.path.join(papers_dir, f"pmc_{pmcid}.pdf")
    if fetch_url(pdf_url, out):
        print(f"Downloaded: {out}")
elif paper_id.startswith('http'):
    fname = re.sub(r'[^a-z0-9]', '_', paper_id.lower())[-60:] + '.pdf'
    out = os.path.join(papers_dir, fname)
    if fetch_url(paper_id, out):
        print(f"Downloaded: {out}")
else:
    print(f"Unknown paper ID format: {paper_id}")
    print("Supported: arXiv IDs (2301.12345), PMC IDs (PMC1234567), or full URLs")
PYEOF
      ;;

    cite)
      local num="${1:-1}"; local fmt="${2:-${PAPERS_CITATION_FORMAT}}"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      "$PYTHON" - "$num" "$fmt" "$PAPERS_DIR" <<'PYEOF'
import sys, os, json

num = int(sys.argv[1]) - 1
fmt = sys.argv[2].lower()
papers_dir = sys.argv[3]
idx_file = os.path.join(papers_dir, 'search_results.json')
if not os.path.exists(idx_file):
    print("No search results. Run: ai papers search <query>")
    sys.exit(1)
papers = json.load(open(idx_file))
if num < 0 or num >= len(papers):
    print(f"Paper #{num+1} not found. {len(papers)} papers available.")
    sys.exit(1)
p = papers[num]
authors = p.get('authors', ['Unknown Author'])
title = p.get('title', 'Unknown Title')
year = p.get('year', 'n.d.')
url = p.get('url', '')
source = p.get('source', '')

# APA
if fmt in ('apa',):
    a_str = ', '.join(authors[:3])
    if len(authors) > 3: a_str += ', et al.'
    print(f"{a_str} ({year}). {title}. {source}. {url}")
# MLA
elif fmt in ('mla',):
    a_str = authors[0] if authors else 'Unknown'
    if len(authors) > 1: a_str += ', et al'
    print(f'{a_str}. "{title}." {source}, {year}. Web. {url}')
# Chicago
elif fmt in ('chicago',):
    a_str = ', '.join(authors[:3])
    print(f'{a_str}. "{title}." {source} ({year}). {url}.')
# BibTeX
elif fmt in ('bibtex', 'bib'):
    key = (authors[0].split()[-1] if authors else 'Unknown') + year
    print(f"@article{{{key},")
    print(f"  title     = {{{title}}},")
    print(f"  author    = {{{' and '.join(authors)}}},")
    print(f"  year      = {{{year}}},")
    print(f"  journal   = {{{source}}},")
    print(f"  url       = {{{url}}}")
    print("}")
# IEEE
elif fmt in ('ieee',):
    a_str = ', '.join(authors[:3])
    if len(authors) > 3: a_str += ' et al.'
    print(f'{a_str}, "{title}," {source}, {year}. [Online]. Available: {url}')
else:
    print(f"Unknown citation format: {fmt}")
    print("Supported: apa mla chicago bibtex ieee")
PYEOF
      ;;

    list)
      local idx="$PAPERS_DIR/search_results.json"
      [[ ! -f "$idx" ]] && { info "No papers yet. Run: ai papers search <query>"; return 0; }
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "
import json
papers = json.load(open('$idx'))
print(f'{len(papers)} paper(s) in index:')
for i,p in enumerate(papers,1):
    print(f'  [{i}] {p[\"title\"][:70]} ({p[\"year\"]}) [{p[\"source\"]}]')
"
      ;;

    format)
      if [[ -n "${1:-}" ]]; then
        PAPERS_CITATION_FORMAT="$1"; save_config; ok "Default citation format: $1"
      else
        echo "Current: $PAPERS_CITATION_FORMAT"
        echo "Options: apa mla chicago bibtex ieee"
      fi
      ;;

    help|*)
      hdr "AI CLI — Research Paper Scraper (v2.5)"
      echo "  Open-access sources: arXiv, PubMed Central, CORE, OpenAlex"
      echo "  Citation formats:    APA, MLA, Chicago, BibTeX, IEEE"
      echo ""
      echo "  ai papers search \"<query>\" [--source arxiv|pmc|core|openalex|all]"
      echo "  ai papers download <arxiv-id|pmc-id|url>   Download PDF"
      echo "  ai papers cite <N> [apa|mla|bibtex|ieee|chicago]  Format citation"
      echo "  ai papers list                              Show indexed papers"
      echo "  ai papers format <fmt>                     Set default citation format"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: BUILD / COMPILE — self-contained XZ bundle
# ════════════════════════════════════════════════════════════════════════════════
