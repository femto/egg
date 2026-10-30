# codeshot

Renders an `.egg` file as a PNG for sharing: the code on the left,
highlighted with the VS Code grammar (`../vscode/syntaxes`), and what
`eggc run` prints on the right.

    npm install
    ./codeshot.mjs ../../examples/complex/word_freq.egg -o word_freq.png

The leading comment block (description and `expect:` lines) is left out.
`--no-run` drops the output panel. The picture is rendered at 2x and is at
least 2480 px wide (1240 at 2x); a long code or output line widens it rather
than being cut off.
It needs Chrome; set `CHROME` to its path if it is not in
`/Applications/Google Chrome.app`.
