import { getCollection } from 'astro:content';
import type { APIRoute } from 'astro';

export const GET: APIRoute = async () => {
  const docs = await getCollection("docs");
  const sorted = docs.sort((a, b) => (a.data.order ?? 99) - (b.data.order ?? 99));

  const lines = [
    "# Hornbeam",
    "",
    "> WSGI/ASGI HTTP server powered by the BEAM. Python web apps with Erlang's concurrency, distribution, and fault tolerance.",
    "",
    "## Docs",
    "",
    ...sorted.map(
      (doc) =>
        `- [${doc.data.title}](https://hornbeam.dev/docs/${doc.slug}): ${doc.data.description ?? ""}`
    ),
    "",
    "## Optional",
    "",
    "- [Full Documentation](https://hornbeam.dev/llms-full.txt): All documentation in a single file",
    "- [GitHub](https://github.com/benoitc/hornbeam): Source code",
    "- [Erlang Python](https://hexdocs.pm/erlang_python): Underlying Erlang-Python integration library",
    "",
  ];

  return new Response(lines.join("\n"), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
