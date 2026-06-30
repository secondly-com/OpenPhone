import { getPageImage, source } from '@/lib/source';
import { appName } from '@/lib/shared';
import { generate as DefaultImage } from 'fumadocs-ui/og';
import { ImageResponse } from 'next/og';
import { notFound } from 'next/navigation';

export const revalidate = false;

type RouteProps = {
  params: Promise<{
    slug: string[];
  }>;
};

export async function GET(_req: Request, { params }: RouteProps) {
  const { slug } = await params;
  const page = source.getPage(slug.slice(0, -1));
  if (!page) notFound();

  return new ImageResponse(
    <DefaultImage title={page.data.title} description={page.data.description} site={appName} />,
    {
      width: 1200,
      height: 630,
    },
  );
}

export function generateStaticParams() {
  return source.getPages().map((page) => ({
    slug: getPageImage(page).segments,
  }));
}
