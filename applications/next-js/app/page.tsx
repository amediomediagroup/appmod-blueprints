// import { Amplify } from "aws-amplify";
import Footer from "components/layout/footer";
// import outputs from "../amplify_outputs.json";
import { Carousel } from "components/carousel";
import { ThreeItemGrid } from "components/grid/three-items";

// Amplify.configure(outputs);

export default async function HomePage() {
  return (
    <>
      <ThreeItemGrid />
      <Carousel />
      <Footer />
    </>
  );
}
