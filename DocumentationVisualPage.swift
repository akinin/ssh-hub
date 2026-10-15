import Foundation

// Only locally generated, escaped Markdown enters this page. Pasting is plain text;
// the editor never loads remote resources, executes document HTML or follows links.
enum DocumentationVisual {
    static func page(_ markdown: String) -> String {
        DocumentationMarkdown.page(markdown)
            .replacingOccurrences(of: "</style>", with: """
            main{min-height:calc(100vh - 48px);outline:none;white-space:pre-wrap}main:empty:before{content:'Начни писать…';color:GrayText}li{white-space:pre-wrap}input[type=checkbox]{margin-right:8px}td,th{min-width:90px}pre{white-space:pre-wrap}::selection{background:#368bfa55}
            </style>
            """)
            .replacingOccurrences(of: "<body>", with: "<body><main id=\"editor\" contenteditable=\"true\" role=\"textbox\" aria-label=\"Визуальный редактор документации\" aria-multiline=\"true\">")
            .replacingOccurrences(of: "</body>", with: "</main></body>")
    }
    static let script = #"""
    (() => {
      const root = document.getElementById('editor');
      if (!root) return;
      // The preview's compact list rows become editable semantic lists.
      root.querySelectorAll('div.list').forEach(row => {
        const text = row.textContent, list = document.createElement(/^\d+\. /.test(text) ? 'ol' : 'ul');
        const li = document.createElement('li');
        if (/^\d+\. /.test(text)) { list.start = parseInt(text); row.innerHTML = row.innerHTML.replace(/^\d+\. /, ''); }
        else if (/^[☐☑] /.test(text)) {
          li.dataset.task = 'true';
          const checked = text.startsWith('☑');
          row.innerHTML = row.innerHTML.replace(/^[☐☑] /, '');
          const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.checked = checked;
          li.append(checkbox);
        } else row.innerHTML = row.innerHTML.replace(/^• /, '');
        while (row.firstChild) li.append(row.firstChild);
        list.append(li); row.replaceWith(list);
      });
      let selection = null, last = null;
      const bridge = (type, value = '') => window.webkit?.messageHandlers.documentation?.postMessage({type, value});
      const escape = text => text.replace(/([\\`*_\[\]<>#|~+.!-])/g, '\\$1').replace(/\u00a0/g, ' ');
      const children = node => Array.from(node.childNodes).map(inline).join('');
      function inline(node) {
        if (node.nodeType === Node.TEXT_NODE) return escape(node.textContent);
        if (node.nodeType !== Node.ELEMENT_NODE) return '';
        const value = children(node);
        switch (node.tagName) {
          case 'BR': return '  \n';
          case 'B': case 'STRONG': return value.trim() ? '**' + value + '**' : value;
          case 'I': case 'EM': return value.trim() ? '*' + value + '*' : value;
          case 'S': case 'STRIKE': case 'DEL': return value.trim() ? '~~' + value + '~~' : value;
          case 'CODE': return '`' + node.textContent.replace(/`/g, '\\`') + '`';
          case 'A': {
            const href = node.getAttribute('href') || '';
            return /^(https?:\/\/|mailto:)/i.test(href) ? '[' + value + '](' + href.replace(/\)/g, '%29') + ')' : value;
          }
          case 'INPUT': return '';
          default: return value;
        }
      }
      function block(node) {
        if (node.nodeType !== Node.ELEMENT_NODE) return inline(node);
        const tag = node.tagName;
        if (/^(B|STRONG|I|EM|S|STRIKE|DEL|CODE|A|SPAN|BR)$/.test(tag)) return inline(node);
        if (/^H[1-6]$/.test(tag)) return '#'.repeat(Number(tag[1])) + ' ' + children(node).trim();
        if (tag === 'PRE') {
          const text = node.textContent.replace(/\n$/, '');
          const longest = Math.max(2, ...(text.match(/`+/g) || []).map(run => run.length));
          const fence = '`'.repeat(longest + 1);
          return fence + '\n' + text + '\n' + fence;
        }
        if (tag === 'BLOCKQUOTE') return blocks(node).split('\n').map(line => '> ' + line).join('\n');
        if (tag === 'UL' || tag === 'OL') {
          let number = Number(node.getAttribute('start')) || 1;
          return Array.from(node.children).filter(li => li.tagName === 'LI').map(li => {
            const checkbox = li.querySelector(':scope > input[type=checkbox]');
            const prefix = checkbox ? '- [' + (checkbox.checked ? 'x' : ' ') + '] ' : tag === 'OL' ? (number++) + '. ' : '- ';
            return prefix + children(li).trim();
          }).join('\n');
        }
        if (tag === 'TABLE') {
          const rows = Array.from(node.rows).map(row => Array.from(row.cells).map(cell => children(cell).trim().replace(/\n/g, ' ')));
          if (!rows.length) return '';
          const width = Math.max(...rows.map(row => row.length));
          const line = row => '| ' + Array.from({length:width}, (_,i) => row[i] || '').join(' | ') + ' |';
          return [line(rows[0]), line(Array(width).fill('---')), ...rows.slice(1).map(line)].join('\n');
        }
        if (tag === 'HR') return '---';
        if (tag === 'DIV' && node.querySelector(':scope > table')) return block(node.querySelector(':scope > table'));
        if (tag === 'DIV' && Array.from(node.children).some(child => /^(P|DIV|UL|OL|H[1-6]|BLOCKQUOTE|PRE|TABLE)$/.test(child.tagName))) return blocks(node);
        return children(node).replace(/(?: {2}\n)+$/, '');
      }
      function blocks(parent) {
        const parts = []; let run = '';
        const flush = () => { if (run) { parts.push(run); run = ''; } };
        Array.from(parent.childNodes).forEach(node => {
          if (node.nodeType === Node.ELEMENT_NODE && /^(P|DIV|H[1-6]|PRE|BLOCKQUOTE|UL|OL|TABLE|HR)$/.test(node.tagName)) { flush(); parts.push(block(node)); }
          else run += inline(node);
        });
        flush(); return parts.join('\n\n').replace(/\n{3,}/g, '\n\n').trim();
      }
      function serialize() { return blocks(root); }
      function changed() {
        const text = serialize();
        if (new TextEncoder().encode(text).length > 262144) { document.execCommand('undo'); bridge('error', 'Документ должен быть не больше 256 КБ.'); return; }
        if (text !== last) { last = text; bridge('change', text); }
      }
      function remember() {
        const current = window.getSelection();
        if (current.rangeCount && root.contains(current.anchorNode)) selection = current.getRangeAt(0).cloneRange();
      }
      function restore() {
        root.focus();
        const current = window.getSelection(); current.removeAllRanges();
        if (selection && root.contains(selection.startContainer)) current.addRange(selection);
        else { const range = document.createRange(); range.selectNodeContents(root); range.collapse(false); current.addRange(range); }
      }
      root.addEventListener('input', changed);
      root.addEventListener('change', changed);
      root.addEventListener('paste', event => { event.preventDefault(); document.execCommand('insertText', false, event.clipboardData.getData('text/plain')); });
      root.addEventListener('drop', event => event.preventDefault());
      root.addEventListener('click', event => { if (event.target.closest('a')) event.preventDefault(); });
      document.addEventListener('selectionchange', remember);
      root.addEventListener('keydown', event => {
        if (event.metaKey && ['s','f'].includes(event.key.toLowerCase())) { event.preventDefault(); bridge(event.key.toLowerCase() === 's' ? 'save' : 'find'); }
        if (event.key === 'Tab' && event.target.closest('td,th')) {
          event.preventDefault(); const cells = Array.from(root.querySelectorAll('td,th')), index = cells.indexOf(event.target.closest('td,th'));
          const cell = cells[index + (event.shiftKey ? -1 : 1)]; if (cell) { const range = document.createRange(); range.selectNodeContents(cell); window.getSelection().removeAllRanges(); window.getSelection().addRange(range); }
        }
      });
      window.hubEditor = {
        serialize,
        command(command, value) {
          restore();
          if (command === 'link') {
            const label = value.label || window.getSelection().toString() || value.url;
            const a = document.createElement('a'); a.textContent = label; a.setAttribute('href', value.url);
            document.execCommand('insertHTML', false, a.outerHTML);
          } else if (command === 'html') document.execCommand('insertHTML', false, value);
          else document.execCommand(command, false, value || null);
          remember(); changed();
        },
        find(query, backwards, replacement) {
          if (!query) return false;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), nodes = []; let node;
          while (node = walker.nextNode()) nodes.push(node);
          const matches = [];
          nodes.forEach(node => { let from = 0, at; while ((at = node.textContent.toLocaleLowerCase().indexOf(query.toLocaleLowerCase(), from)) >= 0) { matches.push({node,at}); from = at + query.length; } });
          if (!matches.length) return false;
          let index = matches.findIndex(match => selection && match.node === selection.startContainer && match.at === selection.startOffset && selection.toString().toLocaleLowerCase() === query.toLocaleLowerCase());
          if (replacement !== null && index >= 0) { restore(); document.execCommand('insertText', false, replacement); remember(); changed(); return true; }
          index = index < 0 ? (backwards ? matches.length - 1 : 0) : (index + (backwards ? -1 : 1) + matches.length) % matches.length;
          const match = matches[index], range = document.createRange(); range.setStart(match.node, match.at); range.setEnd(match.node, match.at + query.length);
          selection = range; restore(); range.startContainer.parentElement.scrollIntoView({block:'nearest'}); return true;
        }
      };
      last = serialize();
    })();
    """#
}
