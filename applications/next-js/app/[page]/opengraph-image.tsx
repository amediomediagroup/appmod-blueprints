import OpengraphImage from "components/opengraph-image";
import { getPage } from "lib/dynamo";

export const runtime = "edge";

export default async function Image({ params }: { params: { page: string } }) {
  const page = await getPage(params.page);
  const title = page.title || page.title;

  return await OpengraphImage({ title });
}
