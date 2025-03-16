#pragma once
#include <vulkan/vulkan.hpp>
#include "../../Application/Window.h"
#include "GPU.h"

/**
 * @file SwapChain.h
 * @brief Gestiona el intercambio de imágenes y recursos de presentación en Vulkan.
 */

namespace Engine::Graphic
{
	/**
		* @class SwapChain
		* @brief Clase que gestiona el swap chain, render pass, framebuffers y recursos de sincronización en Vulkan.
		*
		* Se encarga de crear y gestionar el swap chain de la aplicación, incluyendo la configuración de imágenes, image views, 
		* render pass, framebuffers, recursos de profundidad, y objetos de sincronización como semáforos y fences.
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
			* @param window Referencia a la ventana de la aplicación.
			*/
		SwapChain(GPU& gpu, Application::Window& window);
			
		/**
			* @brief Destructor que limpia los recursos asignados al swap chain.
			*/
		~SwapChain();

		/**
			* @brief Recrea el swap chain, útil cuando ocurre un cambio en la ventana o superficie.
			*/
		void recreateSwapChain();
			
		/**
			* @brief Adquiere la siguiente imagen disponible del swap chain.
			*
			* @param imageIndex Índice de la imagen adquirida.
			* @return VkResult Resultado de la operación.
			*/
		VkResult adquireNextImage(uint32_t imageIndex);
			
		/**
			* @brief Reinicia los fences de sincronización para el frame actual.
			*
			* @param currentFrame Índice del frame actual.
			*/
		void resetFences(uint32_t currentFrame);
			
		/**
			* @brief Inicia el render pass en el buffer de comandos.
			*
			* @param commandBuffer Buffer de comandos donde se iniciará el render pass.
			* @param imageIndex Índice de la imagen actual.
			*/
		void beginRenderPass(VkCommandBuffer commandBuffer, uint32_t imageIndex);
			
		/**
			* @brief Obtiene las dimensiones actuales del swap chain.
			*
			* @return VkExtent2D Extensión del swap chain.
			*/
		VkExtent2D getExtent() const { return _swapChainExtent; }
			
		/**
			* @brief Envía el buffer de comandos a la cola de presentación.
			*
			* @param commandBuffer Buffer de comandos a enviar.
			* @param currentFrame Índice del frame actual.
			* @return VkResult Resultado del envío.
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
		/// Referencia a la ventana de la aplicación.
		Application::Window& _window;
		/// Handle del swap chain actual.
		VkSwapchainKHR _swapChain = VK_NULL_HANDLE;
		/// Handle del swap chain antiguo.
		VkSwapchainKHR _oldSwapchain = VK_NULL_HANDLE;
		/// Imágenes del swap chain.
		std::vector<VkImage> _swapChainImages;
		/// Formato de las imágenes del swap chain.
		VkFormat _swapChainImageFormat;
		/// Extensión del swap chain.
		VkExtent2D _swapChainExtent;
		/// Image views asociadas a las imágenes del swap chain.
		std::vector<VkImageView> _swapChainImageViews;
		/// Render pass utilizado para la presentación.
		VkRenderPass _renderPass;
		/// Framebuffers del swap chain.
		std::vector<VkFramebuffer> _swapChainFramebuffers;
		/// Imagen utilizada para recursos de profundidad.
		VkImage _depthImage;
		/// Memoria asociada a la imagen de profundidad.
		VkDeviceMemory _depthImageMemory;
		/// Image view de la imagen de profundidad.
		VkImageView _depthImageView;
		/// Semáforos para señalizar disponibilidad de imagen.
		std::vector<VkSemaphore> _imageAvailableSemaphores;
		/// Semáforos para señalar finalización de renderización.
		std::vector<VkSemaphore> _renderFinishedSemaphores;
		/// Fences para sincronización de frames en vuelo.
		std::vector<VkFence> _inFlightFences;

		/**
			* @brief Selecciona la extensión adecuada del swap chain basada en las capacidades de la superficie.
			*
			* @param capabilities Capacidades de la superficie.
			* @return VkExtent2D Extensión seleccionada.
			*/
		VkExtent2D chooseSwapExtent(const VkSurfaceCapabilitiesKHR& capabilities);
			
		/**
			* @brief Selecciona el modo de presentación óptimo del swap chain.
			*
			* @param availablePresentModes Lista de modos de presentación disponibles.
			* @return VkPresentModeKHR Modo de presentación seleccionado.
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
			* @brief Crea los image views para las imágenes del swap chain.
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
			* @brief Crea una imagen de Vulkan con los parámetros especificados.
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
			* @brief Busca un formato soportado basado en candidatos, tiling y características.
			*
			* @param candidates Lista de formatos candidatos.
			* @param tiling Tiling deseado.
			* @param features Características requeridas.
			* @return VkFormat Formato soportado.
			*/
		VkFormat findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features);
			
		/**
			* @brief Crea los recursos de profundidad necesarios para el swap chain.
			*/
		void createDepthResources();

		/**
			* @brief Crea el render pass para la presentación.
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
			* @brief Crea los objetos de sincronización (semáforos y fences) para el swap chain.
			*/
		void createSyncObjects();
	};
}
