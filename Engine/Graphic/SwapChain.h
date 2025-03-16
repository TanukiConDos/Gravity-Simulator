#pragma once
#include <vulkan/vulkan.hpp>
#include "../../Application/Window.h"
#include "GPU.h"

/**
 * @file SwapChain.h
 * @brief Gestiona el intercambio de im�genes y recursos de presentaci�n en Vulkan.
 */

namespace Engine::Graphic
{
	/**
		* @class SwapChain
		* @brief Clase que gestiona el swap chain, render pass, framebuffers y recursos de sincronizaci�n en Vulkan.
		*
		* Se encarga de crear y gestionar el swap chain de la aplicaci�n, incluyendo la configuraci�n de im�genes, image views, 
		* render pass, framebuffers, recursos de profundidad, y objetos de sincronizaci�n como sem�foros y fences.
		*/
	class SwapChain
	{
	public:
		SwapChain(const SwapChain&) = delete;
		SwapChain& operator= (const SwapChain&) = delete;
			
		/**
			* @brief Constructor de la clase SwapChain.
			*
			* Inicializa el swap chain utilizando la GPU y la ventana proporcionadas.
			*
			* @param gpu Referencia a la instancia de GPU.
			* @param window Referencia a la ventana de la aplicaci�n.
			*/
		SwapChain(GPU& gpu, Application::Window& window);
			
		/**
			* @brief Destructor que limpia los recursos asignados al swap chain.
			*/
		~SwapChain();

		/**
			* @brief Recrea el swap chain, �til cuando ocurre un cambio en la ventana o superficie.
			*/
		void recreateSwapChain();
			
		/**
			* @brief Adquiere la siguiente imagen disponible del swap chain.
			*
			* @param imageIndex �ndice de la imagen adquirida.
			* @return VkResult Resultado de la operaci�n.
			*/
		VkResult adquireNextImage(uint32_t imageIndex);
			
		/**
			* @brief Reinicia los fences de sincronizaci�n para el frame actual.
			*
			* @param currentFrame �ndice del frame actual.
			*/
		void resetFences(uint32_t currentFrame);
			
		/**
			* @brief Inicia el render pass en el buffer de comandos.
			*
			* @param commandBuffer Buffer de comandos donde se iniciar� el render pass.
			* @param imageIndex �ndice de la imagen actual.
			*/
		void beginRenderPass(VkCommandBuffer commandBuffer, uint32_t imageIndex);
			
		/**
			* @brief Obtiene las dimensiones actuales del swap chain.
			*
			* @return VkExtent2D Extensi�n del swap chain.
			*/
		VkExtent2D getExtent() const { return _swapChainExtent; }
			
		/**
			* @brief Env�a el buffer de comandos a la cola de presentaci�n.
			*
			* @param commandBuffer Buffer de comandos a enviar.
			* @param currentFrame �ndice del frame actual.
			* @return VkResult Resultado del env�o.
			*/
		VkResult queueSubmit(VkCommandBuffer commandBuffer, uint32_t currentFrame);
			
		/**
			* @brief Obtiene el render pass asociado al swap chain.
			*
			* @return VkRenderPass Render pass actual.
			*/
		VkRenderPass getRenderPass() const { return _renderPass; }
	private:
		/// Referencia a la GPU utilizada para gestionar recursos Vulkan.
		GPU& _gpu;
		/// Referencia a la ventana de la aplicaci�n.
		Application::Window& _window;
		/// Handle del swap chain actual.
		VkSwapchainKHR _swapChain = VK_NULL_HANDLE;
		/// Handle del swap chain antiguo.
		VkSwapchainKHR _oldSwapchain = VK_NULL_HANDLE;
		/// Im�genes del swap chain.
		std::vector<VkImage> _swapChainImages;
		/// Formato de las im�genes del swap chain.
		VkFormat _swapChainImageFormat;
		/// Extensi�n del swap chain.
		VkExtent2D _swapChainExtent;
		/// Image views asociadas a las im�genes del swap chain.
		std::vector<VkImageView> _swapChainImageViews;
		/// Render pass utilizado para la presentaci�n.
		VkRenderPass _renderPass;
		/// Framebuffers del swap chain.
		std::vector<VkFramebuffer> _swapChainFramebuffers;
		/// Imagen utilizada para recursos de profundidad.
		VkImage _depthImage;
		/// Memoria asociada a la imagen de profundidad.
		VkDeviceMemory _depthImageMemory;
		/// Image view de la imagen de profundidad.
		VkImageView _depthImageView;
		/// Sem�foros para se�alizar disponibilidad de imagen.
		std::vector<VkSemaphore> _imageAvailableSemaphores;
		/// Sem�foros para se�alar finalizaci�n de renderizaci�n.
		std::vector<VkSemaphore> _renderFinishedSemaphores;
		/// Fences para sincronizaci�n de frames en vuelo.
		std::vector<VkFence> _inFlightFences;

		/**
			* @brief Selecciona la extensi�n adecuada del swap chain basada en las capacidades de la superficie.
			*
			* @param capabilities Capacidades de la superficie.
			* @return VkExtent2D Extensi�n seleccionada.
			*/
		VkExtent2D chooseSwapExtent(const VkSurfaceCapabilitiesKHR& capabilities);
			
		/**
			* @brief Selecciona el modo de presentaci�n �ptimo del swap chain.
			*
			* @param availablePresentModes Lista de modos de presentaci�n disponibles.
			* @return VkPresentModeKHR Modo de presentaci�n seleccionado.
			*/
		VkPresentModeKHR chooseSwapPresentMode(const std::vector<VkPresentModeKHR>& availablePresentModes);
			
		/**
			* @brief Selecciona el formato de superficie adecuado para el swap chain.
			*
			* @param availableFormats Lista de formatos disponibles.
			* @return VkSurfaceFormatKHR Formato de superficie seleccionado.
			*/
		VkSurfaceFormatKHR chooseSwapSurfaceFormat(const std::vector<VkSurfaceFormatKHR>& availableFormats);

		/**
			* @brief Crea el swap chain y configura sus recursos asociados.
			*/
		void createSwapChain();
			
		/**
			* @brief Crea los image views para las im�genes del swap chain.
			*/
		void createImageViews();
			
		/**
			* @brief Limpia y destruye los recursos del swap chain.
			*/
		void cleanupSwapChain();
			
		/**
			* @brief Crea un image view para una imagen dada.
			*
			* @param image Imagen para la cual se crea el view.
			* @param format Formato de la imagen.
			* @param aspectFlags Indicadores de aspecto para el view.
			* @return VkImageView Image view creado.
			*/
		VkImageView createImageView(VkImage image, VkFormat format, VkImageAspectFlags aspectFlags);
			
		/**
			* @brief Crea una imagen de Vulkan con los par�metros especificados.
			*
			* @param width Ancho de la imagen.
			* @param height Alto de la imagen.
			* @param format Formato de la imagen.
			* @param tiling Tiling de la imagen.
			* @param usage Uso de la imagen.
			* @param properties Propiedades de la memoria.
			* @param image Referencia donde se almacena el handle de la imagen.
			* @param imageMemory Referencia donde se almacena la memoria asignada.
			*/
		void createImage(uint32_t width, uint32_t height, VkFormat format, VkImageTiling tiling, 
			VkImageUsageFlags usage, VkMemoryPropertyFlags properties, VkImage& image, VkDeviceMemory& imageMemory);
			
		/**
			* @brief Busca un formato soportado basado en candidatos, tiling y caracter�sticas.
			*
			* @param candidates Lista de formatos candidatos.
			* @param tiling Tiling deseado.
			* @param features Caracter�sticas requeridas.
			* @return VkFormat Formato soportado.
			*/
		VkFormat findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features);
			
		/**
			* @brief Crea los recursos de profundidad necesarios para el swap chain.
			*/
		void createDepthResources();

		/**
			* @brief Crea el render pass para la presentaci�n.
			*/
		void createRenderPass();
			
		/**
			* @brief Crea los framebuffers asociados al swap chain.
			*/
		void createFramebuffers();
			
		/**
			* @brief Encuentra un formato adecuado para la imagen de profundidad.
			*
			* @return VkFormat Formato de profundidad seleccionado.
			*/
		VkFormat findDepthFormat();
			
		/**
			* @brief Verifica si un formato incluye componentes de stencil.
			*
			* @param format Formato a verificar.
			* @return true si incluye stencil, false en caso contrario.
			*/
		bool hasStencilComponent(VkFormat format);
			
		/**
			* @brief Crea los objetos de sincronizaci�n (sem�foros y fences) para el swap chain.
			*/
		void createSyncObjects();
	};
}
