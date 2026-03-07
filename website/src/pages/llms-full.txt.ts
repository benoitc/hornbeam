import { getCollection } from 'astro:content';
import type { APIRoute } from 'astro';

export const GET: APIRoute = async () => {
  const docs = await getCollection("docs");
  const sorted = docs.sort((a, b) => (a.data.order ?? 99) - (b.data.order ?? 99));

  const sections = sorted.map((doc) => {
    const url = `https://hornbeam.dev/docs/${doc.slug}`;
    return [
      `## ${doc.data.title}`,
      "",
      `URL: ${url}`,
      doc.data.description ? `> ${doc.data.description}` : "",
      "",
      doc.body ?? "",
    ]
      .filter(Boolean)
      .join("\n");
  });

  const content = [
    "# Hornbeam",
    "",
    "> WSGI/ASGI HTTP server powered by the BEAM. Python web apps with Erlang's concurrency, distribution, and fault tolerance.",
    "",
    "---",
    "",
    sections.join("\n\n---\n\n"),
    "",
  ].join("\n");

  return new Response(content, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
