class Search {
    constructor({ form, input, list, resultTitle, resultTitleTemplate }) {
        this.form = form;
        this.input = input;
        this.list = list;
        this.resultTitle = resultTitle;
        this.resultTitleTemplate = resultTitleTemplate;
        this.container = list.parentElement;

        if (this.input.value.trim() !== '') {
            this.doSearch(this.input.value.split(' '));
        } else {
            this.handleQueryString();
        }

        this.bindQueryStringChange();
        this.bindSearchForm();
    }

    static escapeHTML(str) {
        return str.replace(/[&<>"]/g, tag => ({
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            '"': '&quot;'
        }[tag] || tag));
    }

    static highlight(text, keywords) {
        const regex = new RegExp(`(${keywords.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
        return text.replace(regex, '<mark>$1</mark>');
    }

    async getData() {
        if (!this.data) {
            const jsonURL = this.form.dataset.json;
            this.data = await fetch(jsonURL).then(res => res.json());

            const parser = new DOMParser();
            this.data.forEach(item => {
                item.content = parser.parseFromString(item.content, 'text/html').body.innerText;
            });
        }
        return this.data;
    }

    async doSearch(keywords) {
        const start = performance.now();
        const data = await this.getData();

        const results = data.filter(item =>
            keywords.some(k =>
                item.title.toLowerCase().includes(k.toLowerCase()) ||
                item.content.toLowerCase().includes(k.toLowerCase())
            )
        );

        this.list.innerHTML = '';

        results.forEach(item => {
            const article = document.createElement('article');

            const link = document.createElement('a');
            link.href = item.permalink;

            const details = document.createElement('div');
            details.className = 'article-details';

            const title = document.createElement('h2');
            title.className = 'article-title';
            title.innerHTML = Search.highlight(item.title, keywords);

            const preview = document.createElement('section');
            preview.className = 'article-preview';
            preview.innerHTML = Search.highlight(item.content.slice(0, 140), keywords);

            details.appendChild(title);
            details.appendChild(preview);

            link.appendChild(details);

            if (item.image) {
                const imgWrap = document.createElement('div');
                imgWrap.className = 'article-image';

                const img = document.createElement('img');
                img.src = item.image;
                img.loading = 'lazy';

                imgWrap.appendChild(img);
                link.appendChild(imgWrap);
            }

            article.appendChild(link);
            this.list.appendChild(article);
        });

        const end = performance.now();
        this.resultTitle.innerText = this.resultTitleTemplate
            .replace("#PAGES_COUNT", results.length)
            .replace("#TIME_SECONDS", ((end - start) / 1000).toFixed(2));

        this.container.classList.remove('hidden');
    }

    bindSearchForm() {
        let last = '';

        const handler = (e) => {
            e.preventDefault();
            const keywords = this.input.value.trim();

            if (!keywords) {
                this.list.innerHTML = '';
                this.resultTitle.innerText = '';
                return;
            }

            if (last === keywords) return;
            last = keywords;

            this.doSearch(keywords.split(' '));
        };

        this.input.addEventListener('input', handler);
        this.input.addEventListener('compositionend', handler);
    }

    bindQueryStringChange() {
        window.addEventListener('popstate', () => this.handleQueryString());
    }

    handleQueryString() {
        const keyword = new URL(window.location.href).searchParams.get('keyword') || '';
        this.input.value = keyword;

        if (keyword) {
            this.doSearch(keyword.split(' '));
        }
    }
}

window.addEventListener('load', () => {
    const form = document.querySelector('.search-form');
    const input = form?.querySelector('input');
    const list = document.querySelector('.search-result--list');
    const title = document.querySelector('.search-result--title');

    if (!form || !input || !list || !title) return;

    new Search({
        form,
        input,
        list,
        resultTitle: title,
        resultTitleTemplate: window.searchResultTitleTemplate || "#PAGES_COUNT results (#TIME_SECONDSs)"
    });
});