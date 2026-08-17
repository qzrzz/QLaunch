import type { II18nConfig } from "qpage";

/**
 * QLaunch 官网国际化多语言配置文件
 *
 * 遵循 qpage 配置规范，以简体中文（zh-Hans）为默认语言，
 * 并提供英文(en)、日文(ja)、韩文(ko)、越南文(vi)、葡萄牙文(pt)、西班牙文(es)、德文(de)、法文(fr)、俄文(ru) 9 种目标语言支持。
 * 保持专业、清晰且带有亲和力的表达风格，确保专有名词（QLaunch、macOS、Metal、Liquid Glass、Pinyin、Vibe Coding 等）的统一性。
 */
const i18n: II18nConfig = {
  defaultLang: "zh-Hans",
  langs: {
    // 默认语言（简体中文）
    "zh-Hans": {
      name: "简体中文",
    },

    // 英语 (English)
    en: {
      name: "English",
      page: {
        tagline: "The smoothest macOS application launchpad — simple, seamless, visually stunning, free and open source.",
        metaDesc:
          "The smoothest macOS application launchpad. Simple, seamless, visually stunning, free and open source, powered by Metal GPU rendering.",
      },
      sections: [
        {
          id: "why",
          title: "Why Choose QLaunch",
          description:
            "Delivers smoother operations and higher rendering quality than alternative tools. Featuring 120Hz refresh rate, Display-P3 wide color gamut, Liquid Glass visual effects, responsive animations, and Pinyin search. High-quality execution of core features, so seamless you'll barely notice it's there.",
        },
        {
          id: "what",
          title: "What is QLaunch",
          description:
            "QLaunch is a macOS application launchpad — displaying system applications and launching them effortlessly. Starting with macOS 26, Apple phased out Launchpad in favor of a small Spotlight search box, but we still cherish the delightful, full-screen experience of beautifully presented app icons.",
        },
        {
          id: "performance",
          title: "Metal High-Performance GPU Rendering",
          description:
            "QLaunch leverages Metal for direct GPU image rendering, achieving response rates up to 120 Hz with rendering quality that surpasses comparable tools.",
        },
        {
          id: "pingyin",
          title: "Pinyin Search",
          description:
            "Chinese language users no longer need to switch input methods. Type effortlessly — find target apps instantly whether your input method is set to English or Pinyin.",
        },
        {
          id: "infcolors",
          title: "Infinite Canvas + Color Sorting",
          description:
            "Arrange all your app icons on an infinite canvas, zoom and pan freely, and sort them by icon color.",
        },
        {
          id: "ai",
          title: "AI-Powered App Organization, Open & Free",
          description:
            "Let AI organize your applications. This isn't a paid built-in feature — it's an open API designed for your own AI to call.",
        },
        {
          id: "open",
          title: "High-Quality Core Features, Vibe Code the Rest",
          description:
            "Need more features? The codebase is open source — let your AI Agent bring your custom ideas to life.",
        },
      ],
      ui: {
        download: "Download",
        viewOnGithub: "GitHub",
        langSwitchAria: "Select language",
        otherProducts: "Other Products",
        moreProducts: "More Products",
        productLinks: "Products",
        contact: "Contact",
        officialWebsite: "Website",
        docs: "Docs",
        changelog: "Changelog",
      },
    },

    // 日语 (Japanese)
    ja: {
      name: "日本語",
      page: {
        tagline: "最もスムーズな macOS アプリ Launchpad。シンプルでシームレス、美しく、オープンソースで完全無料。",
        metaDesc:
          "最もスムーズな macOS アプリ Launchpad。シンプル、無感、美しいグラフィック、オープンソース＆無料。Metal GPU レンダリング採用。",
      },
      sections: [
        {
          id: "why",
          title: "なぜ QLaunch を選ぶのか",
          description:
            "同種のツールに比べ、より滑らかな操作性と圧倒的な高画質レンダリングを実現。120Hz のリフレッシュレート、Display-P3 広色域、Liquid Glass エフェクト、滑らかなアニメーション、ピンイン検索に対応。シンプルかつ高品質なコア機能で、存在を忘れるほどの自然な使用感をお届けします。",
        },
        {
          id: "what",
          title: "QLaunch とは",
          description:
            "QLaunch は macOS 用のアプリケーション Launchpad です。システム内のアプリを一覧表示し、すばやく起動します。macOS 26 以降、従来の Launchpad が廃止され小さな Spotlight 検索窓に置き換わりましたが、私たちは全画面に広がる美しいアプリアイコンの爽快な体験を大切にしています。",
        },
        {
          id: "performance",
          title: "Metal による高性能 GPU レンダリング",
          description:
            "QLaunch は Metal を活用して GPU に直接アクセスし画像をレンダリング。最高 120 Hz の圧倒的な応答速度と、他のツールを凌駕する美しい描画品質を提供します。",
        },
        {
          id: "pingyin",
          title: "ピンイン検索",
          description:
            "中国語ユーザーも入力法を切り替える必要はありません。現在の入力モードが英語でもピンインでも、思考を妨げずに直接入力して目的のアプリを検索できます。",
        },
        {
          id: "infcolors",
          title: "無限キャンバス + 色順ソート",
          description:
            "すべてのアプリアイコンを無限キャンバスに並べ、自由にズームやパンをしながら、アイコンの色で並べ替えることができます。",
        },
        {
          id: "ai",
          title: "AI によるアプリ整理、オープン＆無料",
          description:
            "AI にアプリの整理をおまかせ。有料のアプリ内課金機能ではなく、お持ちの AI から自由に呼び出せるオープンな API を提供しています。",
        },
        {
          id: "open",
          title: "高品質なコア機能、残りは Vibe Coding で自由に",
          description:
            "さらに機能が必要ですか？オープンソースなので、AI エージェントを活用して欲しい機能を自由に実装できます。",
        },
      ],
      ui: {
        download: "ダウンロード",
        viewOnGithub: "GitHub",
        langSwitchAria: "言語を選択",
        otherProducts: "その他の製品",
        moreProducts: "その他の製品",
        productLinks: "製品",
        contact: "お問い合わせ",
        officialWebsite: "公式サイト",
        docs: "ドキュメント",
        changelog: "更新履歴",
      },
    },

    // 韩语 (Korean)
    ko: {
      name: "한국어",
      page: {
        tagline: "가장 부드러운 macOS 앱 런치패드. 심플함, 자연스러움, 아름다운 디자인, 오픈소스 및 완전 무료.",
        metaDesc:
          "가장 부드러운 macOS 앱 런치패드. 심플하고 직관적이며 뛰어난 비주얼, 오픈소스 및 무료. Metal GPU 렌더링 지원.",
      },
      sections: [
        {
          id: "why",
          title: "왜 QLaunch인가",
          description:
            "동급 도구 대비 더욱 부드러운 조작감과 뛰어난 화질을 선사합니다. 120Hz 주사율, Display-P3 광색역, Liquid Glass 효과, 매끄러운 전환 애니메이션 및 병음 검색 지원. 가장 핵심적인 기능을 고품질로 구현하여 사용 중에도 이질감을 느끼지 못할 만큼 자연스럽습니다.",
        },
        {
          id: "what",
          title: "QLaunch란 무엇인가",
          description:
            "QLaunch는 macOS용 응용 프로그램 런치패드로, 시스템 앱을 한눈에 보여주고 간편하게 실행합니다. macOS 26부터 기존 Launchpad가 제거되고 작은 Spotlight 검색창으로 대체되었지만, 우리는 전체 화면을 가득 채우는 아름다운 앱 아이콘의 시각적 즐거움을 여전히 사랑합니다.",
        },
        {
          id: "performance",
          title: "Metal 고성능 GPU 렌더링",
          description:
            "QLaunch는 Metal을 활용해 GPU 직접 렌더링을 수행하여 최고 120 Hz의 빠른 응답 속도와 동급 최고의 렌더링 품질을 제공합니다.",
        },
        {
          id: "pingyin",
          title: "병음(Pinyin) 검색",
          description:
            "중국어 사용자는 더 이상 입력기를 전환할 필요가 없습니다. 현재 입력 모드가 영문이든 병음이든 상관없이 원하는 앱을 즉시 검색할 수 있습니다.",
        },
        {
          id: "infcolors",
          title: "무한 캔버스 + 색상 정렬",
          description:
            "모든 앱 아이콘을 무한 캔버스에 배치하고 자유롭게 확대·축소하거나 이동하며 아이콘 색상별로 정렬할 수 있습니다.",
        },
        {
          id: "ai",
          title: "AI를 통한 앱 정렬, 개방형 & 무료",
          description:
            "AI가 앱을 유연하게 정리할 수 있도록 도와줍니다. 유료 내장 기능이 아니라, 사용자의 자체 AI가 호출할 수 있는 개방형 API로 제공됩니다.",
        },
        {
          id: "open",
          title: "완벽한 핵심 기능, 나머지는 Vibe Coding으로",
          description:
            "더 많은 기능이 필요하신가요? 오픈소스 코드이므로 AI Agent에게 맡겨 원하는 기능을 자유롭게 구현해보세요.",
        },
      ],
      ui: {
        download: "다운로드",
        viewOnGithub: "GitHub",
        langSwitchAria: "언어 선택",
        otherProducts: "기타 제품",
        moreProducts: "더 많은 제품",
        productLinks: "제품",
        contact: "문의",
        officialWebsite: "공식 웹사이트",
        docs: "문서",
        changelog: "변경 로그",
      },
    },

    // 越南语 (Vietnamese)
    vi: {
      name: "Tiếng Việt",
      page: {
        tagline: "Trình khởi chạy ứng dụng macOS mượt mà nhất — đơn giản, tự nhiên, mãn nhãn, mã nguồn mở và miễn phí.",
        metaDesc:
          "Trình khởi chạy ứng dụng macOS mượt mà nhất. Đơn giản, liền mạch, đồ họa đẹp mắt, mã nguồn mở & miễn phí, hỗ trợ Metal GPU.",
      },
      sections: [
        {
          id: "why",
          title: "Tại sao chọn QLaunch",
          description:
            "Mang lại thao tác mượt mà hơn và chất lượng hiển thị cao hơn so với các công cụ cùng loại. Hỗ trợ tần số quét 120Hz, dải màu rộng Display-P3, hiệu ứng Liquid Glass, chuyển động mượt mà và tìm kiếm Pinyin. Hoàn thiện xuất sắc các tính năng cốt lõi, giúp bạn trải nghiệm tự nhiên đến mức không nhận ra sự tồn tại của nó.",
        },
        {
          id: "what",
          title: "QLaunch là gì",
          description:
            "QLaunch là trình khởi chạy ứng dụng (Launchpad) cho macOS — hiển thị các ứng dụng trong hệ thống và khởi chạy chúng dễ dàng. Từ macOS 26, Apple đã loại bỏ Launchpad để thay bằng ô tìm kiếm Spotlight nhỏ gọn, nhưng chúng tôi vẫn yêu thích trải nghiệm toàn màn hình với những biểu tượng ứng dụng tuyệt đẹp.",
        },
        {
          id: "performance",
          title: "Hiệu năng cao với GPU Metal",
          description:
            "QLaunch tận dụng Metal để trực tiếp render hình ảnh qua GPU, đạt tốc độ phản hồi lên đến 120 Hz cùng chất lượng hình ảnh vượt trội so với các công cụ khác.",
        },
        {
          id: "pingyin",
          title: "Tìm kiếm Pinyin",
          description:
            "Người dùng tiếng Trung không cần phải chuyển đổi bộ gõ. Nhập liệu tự nhiên — tìm thấy ứng dụng tức thì bất kể bộ gõ đang ở chế độ Tiếng Anh hay Pinyin.",
        },
        {
          id: "infcolors",
          title: "Canvas vô hạn + Sắp xếp theo màu",
          description:
            "Sắp xếp mọi biểu tượng ứng dụng trên canvas vô hạn, tự do thu phóng và di chuyển, đồng thời sắp xếp theo màu biểu tượng.",
        },
        {
          id: "ai",
          title: "AI hỗ trợ sắp xếp ứng dụng, mở và miễn phí",
          description:
            "Hãy để AI giúp bạn sắp xếp ứng dụng. Đây không phải là tính năng trả phí tích hợp sẵn, mà là giao diện mở để chính AI của bạn gọi tới.",
        },
        {
          id: "open",
          title: "Tính năng cốt lõi chất lượng, phần còn lại tùy bạn Vibe Coding",
          description:
            "Cần thêm tính năng? Mã nguồn hoàn toàn mở — hãy để AI Agent của bạn thực thi ý tưởng!",
        },
      ],
      ui: {
        download: "Tải về",
        viewOnGithub: "GitHub",
        langSwitchAria: "Chọn ngôn ngữ",
        otherProducts: "Sản phẩm khác",
        moreProducts: "Thêm sản phẩm",
        productLinks: "Sản phẩm",
        contact: "Liên hệ",
        officialWebsite: "Trang web chính thức",
        docs: "Tài liệu",
        changelog: "Nhật ký thay đổi",
      },
    },

    // 葡萄牙语 (Portuguese)
    pt: {
      name: "Português",
      page: {
        tagline: "O Launchpad de aplicativos para macOS mais fluido — simples, imperceptível, deslumbrante, gratuito e de código aberto.",
        metaDesc:
          "O Launchpad de aplicativos para macOS mais fluido. Simples, fluido, visual deslumbrante, código aberto e gratuito, com renderização Metal.",
      },
      sections: [
        {
          id: "why",
          title: "Por que escolher o QLaunch",
          description:
            "Oferece uma operação mais fluida e maior qualidade de renderização em comparação com ferramentas similares. Taxa de atualização de 120Hz, ampla gama de cores Display-P3, efeito Liquid Glass, animações suaves e busca Pinyin. Funcionalidades essenciais com execução de alta qualidade, tão natural que você mal notará sua presença.",
        },
        {
          id: "what",
          title: "O que é o QLaunch",
          description:
            "O QLaunch é um Launchpad de aplicativos para macOS — exibe os aplicativos do sistema e os inicia com facilidade. A partir do macOS 26, a Apple descontinuou o Launchpad em favor de uma pequena caixa de busca Spotlight, mas nós continuamos amando a experiência visual encantadora em tela cheia com belos ícones.",
        },
        {
          id: "performance",
          title: "Renderização de alta performance via GPU Metal",
          description:
            "O QLaunch utiliza Metal para renderizar imagens diretamente pela GPU, alcançando taxas de resposta de até 120 Hz e qualidade de imagem superior a ferramentas similares.",
        },
        {
          id: "pingyin",
          title: "Busca Pinyin",
          description:
            "Usuários de idioma chinês não precisam trocar de método de entrada. Digitação direta — encontre os aplicativos instantaneamente, esteja o teclado em inglês ou Pinyin.",
        },
        {
          id: "infcolors",
          title: "Canvas infinito + Ordenação por cores",
          description:
            "Organize todos os ícones de aplicativos em um canvas infinito, navegue e aplique zoom livremente e ordene-os pela cor do ícone.",
        },
        {
          id: "ai",
          title: "IA para organizar seus apps, aberto e gratuito",
          description:
            "Deixe a IA organizar seus aplicativos. Não é um recurso pago integrado, mas uma API aberta pronta para ser chamada pela sua própria IA.",
        },
        {
          id: "open",
          title: "Recursos essenciais de alta qualidade, o resto é com o seu Vibe Coding",
          description:
            "Precisa de mais recursos? O código é aberto — deixe seu AI Agent transformar suas ideias em realidade.",
        },
      ],
      ui: {
        download: "Baixar",
        viewOnGithub: "GitHub",
        langSwitchAria: "Selecionar idioma",
        otherProducts: "Outros produtos",
        moreProducts: "Mais produtos",
        productLinks: "Produtos",
        contact: "Contato",
        officialWebsite: "Site oficial",
        docs: "Documentação",
        changelog: "Histórico de alterações",
      },
    },

    // 西班牙语 (Spanish)
    es: {
      name: "Español",
      page: {
        tagline: "El Launchpad de aplicaciones para macOS más fluido: simple, transparente, visualmente deslumbrante, gratuito y de código abierto.",
        metaDesc:
          "El Launchpad de aplicaciones para macOS más fluido. Simple, fluido, interfaz deslumbrante, código abierto y gratuito, renderizado por GPU Metal.",
      },
      sections: [
        {
          id: "why",
          title: "Por qué elegir QLaunch",
          description:
            "Ofrece un rendimiento más fluido y mayor calidad de renderizado que otras herramientas similares. Frecuencia de actualización de 120Hz, amplia gama de colores Display-P3, efectos Liquid Glass, animaciones suaves y búsqueda Pinyin. Funcionalidades esenciales ejecutadas con la máxima calidad, tan natural que apenas notarás que está ahí.",
        },
        {
          id: "what",
          title: "Qué es QLaunch",
          description:
            "QLaunch es un Launchpad de aplicaciones para macOS: muestra las aplicaciones del sistema y las inicia sin esfuerzo. A partir de macOS 26, Apple eliminó Launchpad para reemplazarlo por un pequeño cuadro de búsqueda Spotlight, pero nosotros seguimos amando la maravillosa experiencia a pantalla completa repleta de hermosos iconos.",
        },
        {
          id: "performance",
          title: "Renderizado de alto rendimiento por GPU Metal",
          description:
            "QLaunch aprovecha Metal para renderizar imágenes directamente en la GPU, alcanzando velocidades de respuesta de hasta 120 Hz y una calidad de imagen superior a la de herramientas equivalentes.",
        },
        {
          id: "pingyin",
          title: "Búsqueda Pinyin",
          description:
            "Los usuarios de idioma chino ya no necesitan cambiar el método de entrada. Escribe de forma directa y encuentra aplicaciones al instante, ya esté tu teclado en inglés o en Pinyin.",
        },
        {
          id: "infcolors",
          title: "Lienzo infinito + Ordenación por color",
          description:
            "Organiza todos los iconos de aplicaciones en un lienzo infinito, desplázate y amplía libremente, y ordénalos por el color del icono.",
        },
        {
          id: "ai",
          title: "Organización de apps con IA, abierto y gratuito",
          description:
            "Deja que la IA organice tus aplicaciones. No es una función de pago integrada, sino una interfaz abierta para que la invoque tu propia IA.",
        },
        {
          id: "open",
          title: "Funciones principales de alta calidad, el resto hazlo con Vibe Coding",
          description:
            "¿Necesitas más funciones? El código es de fuente abierta: deja que tu AI Agent implemente lo que imagines.",
        },
      ],
      ui: {
        download: "Descargar",
        viewOnGithub: "GitHub",
        langSwitchAria: "Seleccionar idioma",
        otherProducts: "Otros productos",
        moreProducts: "Más productos",
        productLinks: "Productos",
        contact: "Contacto",
        officialWebsite: "Sitio web oficial",
        docs: "Documentación",
        changelog: "Registro de cambios",
      },
    },

    // 德语 (German)
    de: {
      name: "Deutsch",
      page: {
        tagline: "Der flüssigste macOS App-Launchpad — einfach, nahtlos, visuell beeindruckend, kostenlos und Open Source.",
        metaDesc:
          "Der flüssigste macOS App-Launchpad. Einfach, nahtlos, wunderschön, kostenlos & Open Source mit Metal GPU-Rendering.",
      },
      sections: [
        {
          id: "why",
          title: "Warum QLaunch wählen",
          description:
            "Bietet eine flüssigere Bedienung und höhere Bildqualität als vergleichbare Tools. Mit 120Hz Bildwiederholrate, Display-P3 Farbraum, Liquid Glass visuelle Effekte, geschmeidigen Animationen und Pinyin-Suche. Erstklassige Umsetzung der Kernfunktionen, so nahtlos, dass Sie es kaum bemerken werden.",
        },
        {
          id: "what",
          title: "Was ist QLaunch",
          description:
            "QLaunch ist ein Anwendungs-Launchpad für macOS — es zeigt Systemanwendungen übersichtlich an und startet sie mühelos. Seit macOS 26 ersetzt Apple das alte Launchpad durch ein kleines Spotlight-Suchfeld, aber wir lieben weiterhin das großartige Vollbild-Erlebnis wunderschöner App-Icons.",
        },
        {
          id: "performance",
          title: "Metal GPU-Rendering mit Höchstleistung",
          description:
            "QLaunch nutzt Metal für direktes GPU-Rendering und erreicht Reaktionszeiten von bis zu 120 Hz bei einer Bildqualität, die andere Tools übertrifft.",
        },
        {
          id: "pingyin",
          title: "Pinyin-Suche",
          description:
            "Chinesischsprachige Nutzer müssen die Eingabemethode nicht mehr wechseln. Tippen Sie einfach los — Ziel-Apps werden sofort gefunden, egal ob die Tastatur auf Englisch oder Pinyin steht.",
        },
        {
          id: "infcolors",
          title: "Unendliche Arbeitsfläche + Farbsortierung",
          description:
            "Ordnen Sie alle App-Symbole auf einer unendlichen Arbeitsfläche an, zoomen und verschieben Sie frei und sortieren Sie sie nach Symbolfarbe.",
        },
        {
          id: "ai",
          title: "KI-gestützte App-Organisation, offen & kostenlos",
          description:
            "Lassen Sie Ihre Apps von KI organisieren. Kein kostenpflichtiges In-App-Feature, sondern eine offene Schnittstelle für Ihre eigene KI.",
        },
        {
          id: "open",
          title: "Hochwertige Kernfunktionen, den Rest erledigt Ihr Vibe Coding",
          description:
            "Sie benötigen weitere Funktionen? Der Quellcode ist Open Source — lassen Sie Ihren KI-Agenten Ihre Wünsche umsetzen.",
        },
      ],
      ui: {
        download: "Herunterladen",
        viewOnGithub: "GitHub",
        langSwitchAria: "Sprache auswählen",
        otherProducts: "Weitere Produkte",
        moreProducts: "Mehr Produkte",
        productLinks: "Produkte",
        contact: "Kontakt",
        officialWebsite: "Offizielle Website",
        docs: "Dokumentation",
        changelog: "Änderungsprotokoll",
      },
    },

    // 法语 (French)
    fr: {
      name: "Français",
      page: {
        tagline: "Le Launchpad d'applications macOS le plus fluide — simple, transparent, visuellement sublime, gratuit et open source.",
        metaDesc:
          "Le Launchpad d'applications macOS le plus fluide. Simple, fluide, visuellement remarquable, gratuit et open source, propulsé par le rendu GPU Metal.",
      },
      sections: [
        {
          id: "why",
          title: "Pourquoi choisir QLaunch",
          description:
            "Offre une fluidité exceptionnelle et une qualité de rendu supérieure aux outils similaires. Taux de rafraîchissement de 120Hz, large gamme de couleurs Display-P3, effets visuels Liquid Glass, animations fluides et recherche Pinyin. Des fonctionnalités essentielles exécutées avec précision, si naturelles que vous en oublierez sa présence.",
        },
        {
          id: "what",
          title: "Qu'est-ce que QLaunch",
          description:
            "QLaunch est un Launchpad d'applications pour macOS — il affiche les applications du système et les lance en un clin d'œil. Depuis macOS 26, Apple a remplacé Launchpad par une simple barre de recherche Spotlight, mais nous continuons de chérir l'expérience plein écran et le plaisir visuel des magnifiques icônes d'applications.",
        },
        {
          id: "performance",
          title: "Rendu GPU haute performance avec Metal",
          description:
            "QLaunch exploite Metal pour effectuer le rendu directement sur le GPU, atteignant un taux de réponse allant jusqu'à 120 Hz et une qualité d'image qui surpasse les outils équivalents.",
        },
        {
          id: "pingyin",
          title: "Recherche Pinyin",
          description:
            "Les utilisateurs sinophones n'ont plus besoin de changer de méthode de saisie. Tapez directement — vos applications cibles sont trouvées instantanément, que vous soyez en anglais ou en Pinyin.",
        },
        {
          id: "infcolors",
          title: "Canvas infini + Tri par couleur",
          description:
            "Disposez toutes les icônes d'applications sur un canvas infini, zoomez et déplacez-vous librement, puis triez-les selon leur couleur.",
        },
        {
          id: "ai",
          title: "Organisation des apps par IA, ouvert et gratuit",
          description:
            "Laissez l'IA organiser vos applications. Il ne s'agit pas d'une fonctionnalité intégrée payante, mais d'une API ouverte conçue pour être appelée par votre propre IA.",
        },
        {
          id: "open",
          title: "Fonctionnalités clés de haute qualité, le reste en Vibe Coding",
          description:
            "Besoin de plus de fonctionnalités ? Le code source est ouvert — laissez votre Agent IA concrétiser vos idées sur mesure.",
        },
      ],
      ui: {
        download: "Télécharger",
        viewOnGithub: "GitHub",
        langSwitchAria: "Choisir la langue",
        otherProducts: "Autres produits",
        moreProducts: "Plus de produits",
        productLinks: "Produits",
        contact: "Contact",
        officialWebsite: "Site officiel",
        docs: "Documentation",
        changelog: "Journal des modifications",
      },
    },

    // 俄语 (Russian)
    ru: {
      name: "Русский",
      page: {
        tagline: "Самый плавный Launchpad приложений для macOS — простой, незаметный, красивый, бесплатный и с открытым исходным кодом.",
        metaDesc:
          "Самый плавный Launchpad для macOS. Простой, легкий, с великолепной графикой, открытый исходный код и бесплатный, с рендерингом на Metal GPU.",
      },
      sections: [
        {
          id: "why",
          title: "Почему стоит выбрать QLaunch",
          description:
            "Обеспечивает более плавную работу и более высокое качество рендеринга по сравнению с аналогами. Частота обновления 120 Гц, широкий цветовой охват Display-P3, визуальные эффекты Liquid Glass, плавные анимации и поиск по пиньин. Высококачественная реализация ключевых функций — настолько органично, что вы даже не заметите его работы.",
        },
        {
          id: "what",
          title: "Что такое QLaunch",
          description:
            "QLaunch — это Launchpad приложений для macOS, который отображает установленные программы и легко запускает их. Начиная с macOS 26 Apple отказалась от прежнего Launchpad в пользу небольшого поискового окна Spotlight, однако нам по-прежнему нравится полноэкранный режим с эстетичными и красивыми иконками приложений.",
        },
        {
          id: "performance",
          title: "Высокопроизводительный рендеринг на Metal GPU",
          description:
            "QLaunch использует Metal для прямого рендеринга с помощью GPU, достигая частоты отклика до 120 Гц и качества изображения, превосходящего аналогичные инструменты.",
        },
        {
          id: "pingyin",
          title: "Поиск по пиньин (Pinyin)",
          description:
            "Китайскоязычным пользователям больше не нужно переключать раскладку ввода. Вводите текст прямо так — нужные приложения находятся мгновенно, независимо от того, активен ли английский язык или пиньин.",
        },
        {
          id: "infcolors",
          title: "Бесконечный холст + Сортировка по цвету",
          description:
            "Разместите все значки приложений на бесконечном холсте, свободно масштабируйте и перемещайте его, а также сортируйте значки по цвету.",
        },
        {
          id: "ai",
          title: "Организация приложений с помощью ИИ — открыто и бесплатно",
          description:
            "Позвольте ИИ навести порядок в ваших приложениях. Это не платная встроенная функция, а открытый API для вызова вашим собственным ИИ.",
        },
        {
          id: "open",
          title: "Качественный базовый функционал, остальное — в стиле Vibe Coding",
          description:
            "Нужно больше возможностей? Исходный код открыт — дайте вашему ИИ-агенту (AI Agent) задание реализовать любые идеи.",
        },
      ],
      ui: {
        download: "Скачать",
        viewOnGithub: "GitHub",
        langSwitchAria: "Выбрать язык",
        otherProducts: "Другие продукты",
        moreProducts: "Больше продуктов",
        productLinks: "Продукты",
        contact: "Контакты",
        officialWebsite: "Официальный сайт",
        docs: "Документация",
        changelog: "История изменений",
      },
    },
  },
};

export default i18n;
