# attempts.awk: turns Bash command lines (one per line) into command segments.
# Output, tab-separated: cmd, verb, args, full command.  Shell variables assigned earlier in the same command
# (NAME=value; ...) are substituted, and separators inside quotes do not split.
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function mask(s,   i, c, q, out) {   # hide ; | & ( ) { } and backticks inside quotes
  q = ""; out = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
    if (q == "") { if (c == "\"" || c == "'") q = c }
    else if (c == q) q = ""
    else if (c ~ /[;|&(){}`]/) c = sprintf("\001%d\002", index(";|&(){}`", c))
    out = out c }
  return out }
function unmask(s,   i, n, p, d) {
  while (match(s, /\001[0-9]\002/)) { d = substr(s, RSTART + 1, 1); s = substr(s, 1, RSTART - 1) substr(";|&(){}`", d, 1) substr(s, RSTART + RLENGTH) }
  return s }
function subvars(s,   k, guard) {
  for (k in var) {
    guard = 0
    while (guard++ < 20 && match(s, "\\$\\{" k "\\}")) s = substr(s, 1, RSTART - 1) var[k] substr(s, RSTART + RLENGTH)
    guard = 0
    while (guard++ < 20 && match(s, "\\$" k "([^A-Za-z0-9_]|$)")) s = substr(s, 1, RSTART - 1) var[k] substr(s, RSTART + length(k) + 1)
  }
  return s }
{ full = $0; delete var
  line = mask($0)
  gsub(/\$\(|`|\(|\)|\{|\}/, ";", line)
  n = split(line, seg, /&&|\|\||[;|&]/)
  for (i = 1; i <= n; i++) { s = trim(unmask(seg[i])); if (s == "") continue
    if (match(s, /^[A-Za-z_][A-Za-z0-9_]*=/) && s !~ /[ \t]/) { nm = substr(s, 1, RLENGTH - 1); v = substr(s, RLENGTH + 1); gsub(/^["']|["']$/, "", v); var[nm] = subvars(v); continue }
    s = subvars(s)
    m = split(s, w, /[ \t]+/); k = 1
    while (k <= m) {
      if (w[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
      if (w[k] ~ /^(sudo|command|env|nohup|time|builtin|exec)$/) { k++; continue }
      if (w[k] == "xargs") { k++; while (k <= m && w[k] ~ /^-/) k++; continue }
      if (w[k] == "timeout") { k++; while (k <= m && w[k] ~ /^(-|[0-9])/) k++; continue }
      break }
    if (k > m) continue
    v = w[k]; sub(/.*\//, "", v)
    args = ""; for (j = k + 1; j <= m; j++) args = args (args == "" ? "" : " ") w[j]
    gsub(/["']/, "", args)
    print "cmd\t" v "\t" args "\t" full } }
