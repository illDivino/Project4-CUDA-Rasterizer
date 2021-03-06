/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include <thrust/execution_policy.h>
#include <thrust/remove.h>
#include <thrust/sort.h>
#include <thrust/device_vector.h>

#define BACKFACE_CULLING 1
#define PERSP_CORRECT 1
#define SORT_BY_AREA 1
#define BILINEAR 1
#define SAMPLES 1
#define SAMPLE_WEIGHT (1.0f / (SAMPLES * SAMPLES))
#define SAMPLE_JITTER (1.0f / SAMPLES)
#pragma region Assumed
namespace {

	typedef unsigned short VertexIndex;
	typedef unsigned char TextureData;
	typedef unsigned char BufferByte;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;

	enum PrimitiveType {
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {

		glm::vec4 vertexEyePos; //the position before perspective distort (Eye Space)
		glm::vec4 vertexPerspPos; //the position in Final Device Coords
		glm::vec3 vertexNormal; //Eye Space Normal
		glm::vec2 vertexUV; //Built-in UV
		TextureData* diffuseTexture = NULL;
		int texWidth, texHeight;
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
		bool cull;
	};

	struct Fragment {
		glm::vec3 eyeNormal;
		glm::vec2 UV;
		TextureData* diffuseTexture = NULL;
		int texWidth, texHeight;
	};

	struct PrimitiveDevBufPointers {
		//from tinygltfloader macro
		int primitiveMode;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		PrimitiveType primitiveType;
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;
	};

}

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;

static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
thrust::device_ptr<Primitive> dev_thrust_primitives;

static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;
static int * dev_depth = NULL;

//write to PBO
__global__
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * w);

	if (x < w && y < h) {
		glm::vec3 color;
		color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
		color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
		color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

#define inverse255 0.00392156863f //1/255 for conversion from unit to 8bit color
__device__ glm::vec3 colorAtPoint(TextureData* t, int index) {
	return inverse255 * glm::vec3(
		(float)t[index * 3],
		(float)t[index * 3 + 1],
		(float)t[index * 3 + 2]
	);
}
#pragma endregion 

//baseline sample floors the uv and returns a single color
__device__ glm::vec3 sample(glm::vec2 uv, TextureData* tex, int texWidth, int texHeight) {
	int uIndex = uv[0] * texWidth;
	int vIndex = uv[1] * texHeight;
	int Index1D = uIndex + texWidth * vIndex;

	return colorAtPoint(tex, Index1D);
}

//biliear sample does four color reads and weights them according to the continuous uv value
__device__ glm::vec3 sampleBilinear(glm::vec2 uv, TextureData* tex, int texWidth, int texHeight) {
	float uFraction = uv[0] * texWidth;
	int uIndex = uFraction;
	uFraction -= uIndex;

	float vFraction = uv[1] * texHeight;
	int vIndex = vFraction;
	vFraction -= vIndex;

	int Index1D = uIndex + texWidth * vIndex;

	return
		(1.0f - uFraction)*(1.0f - vFraction) * colorAtPoint(tex, Index1D) + //current pixel
		uFraction * (1.0f - vFraction) * colorAtPoint(tex, uIndex + 1 < texWidth ? Index1D + 1 : Index1D) + //next u pixel (if exists)
		(1.0f - uFraction) * vFraction * colorAtPoint(tex, vIndex + 1 < texHeight ? Index1D + texWidth : Index1D) + //next y pixel (if exists)
		uFraction * vFraction * colorAtPoint(tex, uIndex + 1 < texWidth && vIndex + 1 < texHeight ? Index1D + texWidth + 1 : Index1D);
	//^next diagonal pixel (if both right and up exist)
}

__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * w);

	if (x < w && y < h) {
		Fragment f = fragmentBuffer[index];
		if (f.eyeNormal == glm::vec3(0)) {
			framebuffer[index] = glm::vec3(0);
			return;
		}

		glm::vec3 lightDir(1, 1, 1);
		glm::vec3 color;
		if (false || f.diffuseTexture == NULL) color = glm::vec3(1, 1, 1);
		else
#if BILINEAR
			color = sampleBilinear(f.UV, f.diffuseTexture, f.texWidth, f.texHeight);
#else 
			color = sample(f.UV, f.diffuseTexture, f.texWidth, f.texHeight);
#endif

		//compute lambert value by angle; keep it positive
		float lightValue = glm::max(glm::dot(fragmentBuffer[index].eyeNormal, lightDir), 0.4f);
		glm::vec3 diffuse = glm::clamp(color * lightValue, 0.0f, 1.0f);
		framebuffer[index] += SAMPLE_WEIGHT * diffuse;
	}
}

#pragma region Assumed
/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
	width = w;
	height = h;

	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));

	cudaFree(dev_framebuffer);
	cudaMalloc(&dev_framebuffer, width * height * sizeof(glm::vec3));
	cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));

	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(int));

	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {

	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {

			dev_dst[count * componentTypeByteSize * n
				+ offset * componentTypeByteSize
				+ j]

				=

				dev_src[byteOffset
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride)
				+ offset * componentTypeByteSize
				+ j];
		}
	}


}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {

	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	}
	else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode(
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
)
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);

									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;

									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();

					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						numPrimitives,
						numIndices,
						numVertices,

						primitiveType,
						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,

						dev_vertexOut	//VertexOut
					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}


	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
		dev_thrust_primitives = thrust::device_ptr<Primitive>(dev_primitives);
	}


	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());

		//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}

static int curPrimitiveBeginId = 0;

#pragma endregion

__global__
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) {
		int pid;	// id for cur primitives vector
		pid = iid / (int)primitive.primitiveType + curPrimitiveBeginId;
		VertexOut v = primitive.dev_verticesOut[primitive.dev_indices[iid]];
		dev_primitives[pid].v[iid % (int)primitive.primitiveType] = v;
		dev_primitives[pid].cull = v.vertexNormal[2] < 0;
	}

}

__global__
void _vertexTransformAndAssembly(
	int numVertices,
	PrimitiveDevBufPointers primitive,
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal,
	int width, int height) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		glm::vec4 world = glm::vec4(primitive.dev_position[vid], 1.0f);
		glm::vec4 clip = MVP * world;
		clip /= clip.w;

		//NDC -> Screen
		clip.x = (1.0f - clip.x) * width / 2.0f;
		clip.y = (1.0f - clip.y) * height / 2.0f;
#if PERSP_CORRECT
		primitive.dev_verticesOut[vid].vertexUV = (1 / clip.z) * primitive.dev_texcoord0[vid];
#else
		primitive.dev_verticesOut[vid].vertexUV = primitive.dev_texcoord0[vid];
#endif
		//transfer all other necessary attributes
		primitive.dev_verticesOut[vid].vertexPerspPos = clip;
		primitive.dev_verticesOut[vid].vertexEyePos = MV * world;
			primitive.dev_verticesOut[vid].diffuseTexture = primitive.dev_diffuseTex;
			primitive.dev_verticesOut[vid].vertexNormal = glm::normalize(MV_normal * primitive.dev_normal[vid]);
			primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
			primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
	}
}

__device__ static glm::vec3 interpolateBarycentric(glm::vec3 p0, glm::vec3 p1, glm::vec3 p2, glm::vec3 coords) {
	return coords.x * p0 +
		coords.y * p1 +
		coords.z * p2;
}

__device__ static glm::vec2 interpolateBarycentric(glm::vec2 p0, glm::vec2 p1, glm::vec2 p2, glm::vec3 coords) {
	return coords.x * p0 +
		coords.y * p1 +
		coords.z * p2;
}

__device__ static glm::vec2 interpolatePerspective(Primitive p, glm::vec3 coords, float pointDepth) {
	return pointDepth * (
		coords.x * p.v[0].vertexUV +
		coords.y * p.v[1].vertexUV +
		coords.z * p.v[2].vertexUV);
}

//VertexOuts in Primitive Buffer -> Fragments in Fragment Buffer
__global__ void generateFragments(int numPrimitives, Primitive* primitiveBuffer, int width, int height, Fragment* fragmentBuffer, int* depthBuffer, glm::vec2 sampleOffset) {
	int primIdx = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (primIdx >= numPrimitives) return;

	//get the intersected triangle
	Primitive p = primitiveBuffer[primIdx];
	VertexOut p0 = p.v[0];
	VertexOut p1 = p.v[1];
	VertexOut p2 = p.v[2];
	glm::vec3 triangle[3] = { glm::vec3(p0.vertexPerspPos), glm::vec3(p1.vertexPerspPos), glm::vec3(p2.vertexPerspPos) };

	//get upper and lower triangle bounds and restrict them to frustum
	AABB triBounds = getAABBForTriangle(triangle, width, height);

	//simple loop
	for (int x = triBounds.min.x; x < triBounds.max.x; x++) {
		for (int y = triBounds.min.y; y < triBounds.max.y; y++) {

			int fragIndex = y*width + x;
			
			glm::vec3 barycentricCoord = calculateBarycentricCoordinate(triangle, glm::vec2(x, y)+sampleOffset);
			//see if the given pixel is within the triangle's bounds from the current view
			if (isBarycentricCoordInBounds(barycentricCoord)) {
				int fragIndex = y*width + x;
				if (fragIndex > width * height) return;
				float depth = 1.0f / getZAtCoordinate(barycentricCoord, triangle);
				atomicMin(&depthBuffer[fragIndex], (int)(depth * INT_MAX));
				glm::vec3 eyeNormal = interpolateBarycentric(p0.vertexNormal, p1.vertexNormal, p2.vertexNormal, barycentricCoord);
				if (depth * INT_MAX == depthBuffer[fragIndex]) {
					Fragment f;
#if PERSP_CORRECT
					f.UV = interpolatePerspective(p, barycentricCoord, depth);
#else
					f.UV = interpolateBarycentric(p0.vertexUV, p1.vertexUV, p2.vertexUV, barycentricCoord);
#endif
					f.texWidth = p0.texWidth;
					f.texHeight = p0.texHeight;
					f.diffuseTexture = p0.diffuseTexture;
					f.eyeNormal = eyeNormal;
					fragmentBuffer[fragIndex] = f;
				}
			}
		}
	}
}

//helper for remove-if
struct toCull {
	__host__ __device__ bool operator()(Primitive p) {
		return p.cull;
	}
};

//put it all together
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
	int sideLength2d = 8;
	dim3 blockSize2d(sideLength2d, sideLength2d);
	dim3 blockCount2d((width - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Vertex Process & primitive assembly
	curPrimitiveBeginId = 0;
	dim3 numThreadsPerBlock(128);

	auto it = mesh2PrimitivesMap.begin();
	auto itEnd = mesh2PrimitivesMap.end();

	for (; it != itEnd; ++it) {
		auto p = (it->second).begin();	// each primitive
		auto pEnd = (it->second).end();
		for (; p != pEnd; ++p) {
			dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
			dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

			_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> > (p->numVertices, *p, MVP, MV, MV_normal, width, height);
			checkCUDAError("Vertex Processing");
			cudaDeviceSynchronize();
			_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
				(p->numIndices,
					curPrimitiveBeginId,
					dev_primitives,
					*p);
			checkCUDAError("Primitive Assembly");

			curPrimitiveBeginId += p->numPrimitives;
		}
	}
	checkCUDAError("Vertex Processing and Primitive Assembly");

#if BACKFACE_CULLING
	//remove if for culled primitives
	Primitive* new_primitive_end = thrust::remove_if(thrust::device, dev_primitives, dev_primitives + totalNumPrimitives, toCull());//-- 2: cull those paths that don't need any more shading
	int frontPrims = new_primitive_end - dev_primitives;
#else
	int frontPrims = totalNumPrimitives;
#endif

	dim3 numBlocksForPrims((frontPrims + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

	cudaMemset(dev_framebuffer, 0, width*height * sizeof(glm::vec3));

	for (float i = 0; i < SAMPLES; i++) {
		for (float j = 0; j < SAMPLES; j++) {
			glm::vec2 sampleOffset = glm::vec2(i * SAMPLE_JITTER, j * SAMPLE_JITTER);

			cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
			initDepth << <blockCount2d, blockSize2d >> > (width, height, dev_depth);

			// TODO: rasterize
			generateFragments << <numBlocksForPrims, numThreadsPerBlock >> > (frontPrims, dev_primitives, width, height, dev_fragmentBuffer, dev_depth, sampleOffset);
			checkCUDAError("rasterization problem");

			// Copy depthbuffer colors into framebuffer
			render << <blockCount2d, blockSize2d >> > (width, height, dev_fragmentBuffer, dev_framebuffer);
			checkCUDAError("fragment shader");
		}
	}
	// Copy framebuffer into OpenGL buffer for OpenGL previewing
	sendImageToPBO << <blockCount2d, blockSize2d >> > (pbo, width, height, dev_framebuffer);
	checkCUDAError("copy render result to pbo");
}

//clean up
void rasterizeFree() {

	// deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);


			//TODO: release other attributes and materials
		}
	}

	////////////

	cudaFree(dev_primitives);
	dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

	cudaFree(dev_framebuffer);
	dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

	checkCUDAError("rasterize Free");
}
