CUDA Rasterizer
===============

[CLICK ME FOR INSTRUCTION OF THIS PROJECT](./INSTRUCTION.md)

![demogif](renders/demo.gif)

**A rasterization pipeline build in Nvidia's CUDA parallel API. Features perspective-correct, bilinear filtered texture mapping, backface culling with stream compaction, supersampled antialiasing.**
**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 6**

* Daniel Daley-Mongtomery
* Tested on: MacBook Pro, OSX 10.12, i7 @ 2.3GHz, 16GB RAM, GT 750M 2048MB (Personal Machine)

##### Compose Vertices and Assemble primitives
![](renders/reverseCull.PNG)

##### Rasterize Primitives
![](https://www.scratchapixel.com/images/upload/rasterization/raytracing-raster2.png?)


| None        | Some           |
| ------------- |:-------------:|
| ![](renders/duckWithNoAntiAliasing.PNG) | ![duck](renders/DuckWithAntiAliasing.PNG)|

##### Shade Fragments

| None        | Some           |
| ------------- |:-------------:|
| ![](renders/NoPerspectiveCorrection.PNG) | ![](renders/PerspectiveCorrection.PNG)|

| None        | Some           |
| ------------- |:-------------:|
| ![](renders/NoFilteringWith128x128Texture.PNG) | ![](renders/BilinearFilteringWith128x128Texture.PNG)|
| ![](renders/NoFilteringWith512x512Texture.PNG) | ![](renders/BilinearFilteringWith512x512Texture.PNG)|

##### Performance

![](renders/RastPerf.png)

<img src="renders/percent.png" width="500">

### Credits

* [tinygltfloader](https://github.com/syoyo/tinygltfloader) by [@soyoyo](https://github.com/syoyo)
* [glTF Sample Models](https://github.com/KhronosGroup/glTF/blob/master/sampleModels/README.md)
