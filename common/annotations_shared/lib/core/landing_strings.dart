/// The strings of the landing pages (annotations#53), in the order EN,
/// pt-BR, TH. The English text is the accepted H6 wording
/// (df60cc66c5714b299282e601ffeb6d12).
///
/// Thai has no spaces between words. The Thai strings carry an invisible
/// zero-width space (U+200B) between words, so a line can wrap on every
/// renderer, also one without a Thai word dictionary.
const landingStrings = <String, List<String>>{
  // Tabs and top bar
  'tabOverview': ['Overview', 'Visão geral', 'ภาพรวม'],
  'tabFeatures': ['Features', 'Recursos', 'ฟีเจอร์'],
  'tabHowItWorks': ['How it works', 'Como funciona', 'วิธีการ​ทำงาน'],
  'tabEngineering': ['Engineering', 'Engenharia', 'วิศวกรรม'],
  'tabDownload': ['Download', 'Baixar', 'ดาวน์โหลด'],
  'barNotes': ['Notes', 'Notes', 'Notes'],
  'barInstant': ['Instant', 'Instant', 'Instant'],

  // Actions
  'actionDownload': ['Download', 'Baixar', 'ดาวน์โหลด'],
  'actionBrowse': ['Browse notes', 'Ver anotações', 'ดู​บันทึก'],
  'actionInstant': ['Open Instant', 'Abrir Instant', 'เปิด Instant'],

  // Overview
  'overviewTitle': [
    'Write, organize and review your study notes.',
    'Escreva, organize e revise suas anotações de estudo.',
    'เขียน จัดระเบียบ และ​ทบทวน​บันทึก​การ​เรียน​ของ​คุณ',
  ],
  'overviewLead': [
    'Use Notes for lasting work. Use Instant to share a temporary page without signing in.',
    'Use Notes para o trabalho que fica. Use Instant para compartilhar uma página temporária sem entrar na conta.',
    'ใช้ Notes สำหรับ​งาน​ที่​ต้อง​เก็บ​ไว้ ใช้ Instant เพื่อ​แชร์​หน้า​ชั่วคราว​โดย​ไม่​ต้อง​ลงชื่อ​เข้าใช้',
  ],
  'modesTitle': ['Two modes', 'Dois modos', 'สอง​โหมด'],
  'modeInstantTitle': ['Instant', 'Instant', 'Instant'],
  'modeInstantText': [
    'Share a temporary page without signing in. A room expires after 15 minutes.',
    'Compartilhe uma página temporária sem entrar na conta. Uma sala expira depois de 15 minutos.',
    'แชร์​หน้า​ชั่วคราว​โดย​ไม่​ต้อง​ลงชื่อ​เข้าใช้ ห้อง​จะ​หมดอายุ​หลังจาก 15 นาที',
  ],
  'modeNotesTitle': ['Notes', 'Notes', 'Notes'],
  'modeNotesText': [
    'Lasting work on your device. Sync privately or publish when you choose.',
    'Trabalho que fica no seu dispositivo. Sincronize de forma privada ou publique quando quiser.',
    'งาน​ที่​เก็บ​ไว้ใน​อุปกรณ์​ของ​คุณ ซิงค์​แบบ​ส่วนตัว​หรือ​เผยแพร่​เมื่อคุณ​ต้องการ',
  ],
  'startTitle': ['Start here', 'Comece aqui', 'เริ่มต้น​ที่นี่'],
  'startBrowseText': [
    'Read public notes in the browser.',
    'Leia anotações públicas no navegador.',
    'อ่าน​บันทึก​สาธารณะ​ใน​เบราว์เซอร์',
  ],
  'startInstantText': [
    'Open a room and share its link or code.',
    'Abra uma sala e compartilhe o link ou o código.',
    'เปิด​ห้อง​แล้ว​แชร์​ลิงก์​หรือ​รหัส',
  ],
  'startDownloadText': [
    'Choose your platform for installation and update instructions.',
    'Escolha sua plataforma para ver as instruções de instalação e atualização.',
    'เลือก​แพลตฟอร์ม​ของ​คุณ​เพื่อ​ดู​วิธี​ติดตั้ง​และ​อัปเดต',
  ],
  'platformsTitle': ['Platforms', 'Plataformas', 'แพลตฟอร์ม'],
  'platformWritersTitle': [
    'Mac, Linux, iPad and Android tablets',
    'Mac, Linux, iPad e tablets Android',
    'Mac, Linux, iPad และ​แท็บเล็ต Android',
  ],
  'platformWritersText': [
    'Write with full tools.',
    'Escreva com todas as ferramentas.',
    'เขียน​ด้วย​เครื่องมือ​ครบ​ชุด',
  ],
  'platformPhonesTitle': [
    'iPhone and Android phones',
    'iPhone e celulares Android',
    'iPhone และ​โทรศัพท์ Android',
  ],
  'platformPhonesText': [
    'Read and write simple typed notes.',
    'Leia e escreva anotações digitadas simples.',
    'อ่าน​และ​เขียน​บันทึก​แบบ​พิมพ์​อย่าง​ง่าย',
  ],
  'platformBrowserTitle': ['Browser', 'Navegador', 'เบราว์เซอร์'],
  'platformBrowserText': [
    'Browse public notes, use Instant or sign in to read your synced notes.',
    'Veja anotações públicas, use o Instant ou entre na conta para ler suas anotações sincronizadas.',
    'ดู​บันทึก​สาธารณะ ใช้ Instant หรือ​ลงชื่อ​เข้าใช้​เพื่อ​อ่าน​บันทึก​ที่​ซิงค์​ไว้',
  ],
  'recentTitle': [
    'Recent public notes',
    'Anotações públicas recentes',
    'บันทึก​สาธารณะ​ล่าสุด',
  ],
  'recentAll': ['All notes', 'Todas as anotações', 'บันทึก​ทั้งหมด'],

  // Training notice
  'noticeTitle': [
    'An open-source study project',
    'Um projeto de estudo de código aberto',
    'โครงการ​เพื่อ​การ​เรียนรู้​แบบ​โอเพนซอร์ส',
  ],
  'noticeText': [
    'Annotations is an open-source study project. We use note content and transcription corrections to train and improve our models.',
    'Annotations é um projeto de estudo de código aberto. Usamos o conteúdo das anotações e as correções de transcrição para treinar e melhorar nossos modelos.',
    'Annotations เป็น​โครงการ​เพื่อ​การ​เรียนรู้​แบบ​โอเพนซอร์ส เรา​ใช้​เนื้อหา​บันทึก​และ​การ​แก้ไข​การ​ถอด​ข้อความ​เพื่อ​ฝึก​และ​ปรับปรุง​โมเดล​ของ​เรา',
  ],
  'noticePrivate': [
    'Transcription data is sent automatically, including when private note sync is disabled. Private notes remain hidden from other users.',
    'Os dados de transcrição são enviados automaticamente, mesmo com a sincronização privada desligada. Anotações privadas continuam ocultas para outros usuários.',
    'ระบบ​ส่ง​ข้อมูล​การ​ถอด​ข้อความ​โดย​อัตโนมัติ แม้​จะ​ปิด​การ​ซิงค์​บันทึก​ส่วนตัว​ไว้ บันทึก​ส่วนตัว​ยังคง​ซ่อน​จาก​ผู้ใช้​อื่น',
  ],
  'noticeRead': ['Read our', 'Leia nossos', 'อ่าน'],
  'and': ['and', 'e', 'และ'],
  'terms': ['Terms of Use', 'Termos de Uso', 'ข้อกำหนด​การ​ใช้งาน'],
  'privacy': [
    'Privacy Policy',
    'Política de Privacidade',
    'นโยบาย​ความ​เป็น​ส่วนตัว',
  ],

  // Features
  'featuresTitle': ['Features', 'Recursos', 'ฟีเจอร์'],
  'featuresLead': [
    'Only features in this release are listed. Each one says what it needs.',
    'Só aparecem os recursos desta versão. Cada um diz do que precisa.',
    'แสดง​เฉพาะ​ฟีเจอร์​ใน​รุ่น​นี้ แต่ละ​ฟีเจอร์​บอก​สิ่ง​ที่​ต้องใช้',
  ],
  'groupWriting': ['Writing', 'Escrita', 'การ​เขียน'],
  'groupWritingText': [
    'Combine typed text, handwriting, shapes and movable content. Edit curves and group related objects. Nearby content stays in place.',
    'Combine texto digitado, escrita à mão, formas e conteúdo móvel. Edite curvas e agrupe objetos relacionados. O conteúdo ao redor fica no lugar.',
    'รวม​ข้อความ​ที่​พิมพ์ ลายมือ รูปทรง และ​เนื้อหา​ที่​ย้าย​ได้ แก้ไข​เส้น​โค้ง​และ​จัด​กลุ่ม​วัตถุ​ที่​เกี่ยวข้อง เนื้อหา​รอบข้าง​ยัง​อยู่​ที่เดิม',
  ],
  'groupPageContent': ['Page content', 'Conteúdo da página', 'เนื้อหา​ใน​หน้า'],
  'groupPageContentText': [
    'Add files, links, Reports charts and task cards. Features that contact another service require a connection and the appropriate access.',
    'Adicione arquivos, links, gráficos do Reports e cartões de tarefa. Recursos que acessam outro serviço precisam de conexão e do acesso adequado.',
    'เพิ่ม​ไฟล์ ลิงก์ แผนภูมิ​จาก Reports และ​การ์ด​งาน ฟีเจอร์​ที่​ติดต่อ​บริการ​อื่น​ต้องใช้​การ​เชื่อมต่อ​และ​สิทธิ์​ที่​เหมาะสม',
  ],
  'groupStudy': ['Study', 'Estudo', 'การ​เรียน'],
  'groupStudyText': [
    'Export Original or Typed notes as printable PDFs. Open quizzes in browser Certifications.',
    'Exporte anotações Original ou Digitada como PDFs para imprimir. Abra quizzes no Certifications no navegador.',
    'ส่งออก​บันทึก​แบบ​ต้นฉบับ​หรือ​แบบ​พิมพ์​เป็น PDF ที่​พิมพ์​ได้ เปิด​แบบทดสอบ​ใน Certifications บน​เบราว์เซอร์',
  ],
  'groupSharing': ['Sharing', 'Compartilhamento', 'การ​แชร์'],
  'groupSharingText': [
    'Keep notes on your device, explicitly sync them privately or publish selected reading versions. Instant rooms expire after 15 minutes.',
    'Mantenha as anotações no seu dispositivo, sincronize de forma privada quando escolher ou publique versões de leitura selecionadas. Salas Instant expiram depois de 15 minutos.',
    'เก็บ​บันทึก​ไว้ใน​อุปกรณ์ ซิงค์​แบบ​ส่วนตัว​เมื่อคุณ​เลือก หรือ​เผยแพร่​ฉบับ​อ่าน​ที่​เลือก​ไว้ ห้อง Instant หมดอายุ​หลังจาก 15 นาที',
  ],
  'needsNothing': [
    'Works offline, no login',
    'Funciona sem internet e sem login',
    'ใช้งาน​ออฟไลน์​ได้ ไม่​ต้อง​ลงชื่อ​เข้าใช้',
  ],
  'needsInternet': [
    'Needs internet, no login',
    'Precisa de internet, sem login',
    'ต้องใช้​อินเทอร์เน็ต ไม่​ต้อง​ลงชื่อ​เข้าใช้',
  ],
  'needsInternetAndLogin': [
    'Needs internet and sign-in',
    'Precisa de internet e login',
    'ต้องใช้​อินเทอร์เน็ต​และ​ลงชื่อ​เข้าใช้',
  ],
  'featureF01Title': ['Paper', 'Papel', 'กระดาษ'],
  'featureF01Text': [
    'A fixed page for typed text, handwriting, shapes and movable content.',
    'Uma página fixa para texto digitado, escrita à mão, formas e conteúdo móvel.',
    'หน้า​กระดาษ​คงที่​สำหรับ​ข้อความ​ที่​พิมพ์ ลายมือ รูปทรง และ​เนื้อหา​ที่​ย้าย​ได้',
  ],
  'featureF02Title': ['Type and Draw', 'Digitar e Desenhar', 'พิมพ์​และ​วาด'],
  'featureF02Text': [
    'Type and write by hand on the same page, with your system keyboard and your pen.',
    'Digite e escreva à mão na mesma página, com o teclado do sistema e a sua caneta.',
    'พิมพ์​และ​เขียน​ด้วย​มือ​ใน​หน้า​เดียวกัน ด้วย​คีย์บอร์ด​ของ​ระบบ​และ​ปากกา​ของ​คุณ',
  ],
  'featureF03Title': ['Pens', 'Canetas', 'ปากกา'],
  'featureF03Text': [
    'A round pen, a flat pen, a brush pen and a highlighter, with pressure where the device gives it.',
    'Caneta redonda, caneta chata, pincel e marca-texto, com pressão quando o dispositivo oferece.',
    'ปากกา​หัว​กลม ปากกา​หัว​แบน ปากกา​พู่กัน และ​ปากกา​เน้น​ข้อความ พร้อม​แรงกด​เมื่อ​อุปกรณ์​รองรับ',
  ],
  'featureF04Title': ['Point editing', 'Edição por pontos', 'แก้ไข​ทีละ​จุด'],
  'featureF04Text': [
    'Edit the curve of a stroke point by point. Group related objects.',
    'Edite a curva de um traço ponto a ponto. Agrupe objetos relacionados.',
    'แก้ไข​เส้น​โค้ง​ของ​ลายเส้น​ทีละ​จุด จัด​กลุ่ม​วัตถุ​ที่​เกี่ยวข้อง',
  ],
  'featureF05Title': ['Erasers', 'Borrachas', 'ยางลบ'],
  'featureF05Text': [
    'Erase a whole stroke or only part of a line. Nearby content stays in place.',
    'Apague um traço inteiro ou só parte de uma linha. O conteúdo ao redor fica no lugar.',
    'ลบ​ทั้ง​ลายเส้น​หรือ​เพียง​บาง​ส่วน​ของ​เส้น เนื้อหา​รอบข้าง​ยัง​อยู่​ที่เดิม',
  ],
  'featureF06Title': ['Backgrounds', 'Fundos', 'พื้นหลัง'],
  'featureF06Text': [
    'Blank, ruled, grid or dot paper.',
    'Papel liso, pautado, quadriculado ou pontilhado.',
    'กระดาษ​เปล่า มี​เส้น ตาราง หรือ​จุด',
  ],
  'featureF16Title': [
    'View lock and Focus',
    'Trava de visualização e Foco',
    'ล็อก​มุมมอง​และ​โฟกัส',
  ],
  'featureF16Text': [
    'Lock the view while you write, or hide the tools with Focus.',
    'Trave a visualização enquanto escreve ou esconda as ferramentas com o Foco.',
    'ล็อก​มุมมอง​ขณะ​เขียน หรือ​ซ่อน​เครื่องมือ​ด้วย​โฟกัส',
  ],
  'featureF07Title': ['Cards', 'Cartões', 'การ์ด'],
  'featureF07Text': [
    'Add files and links to the page as cards.',
    'Adicione arquivos e links à página como cartões.',
    'เพิ่ม​ไฟล์​และ​ลิงก์​ลงใน​หน้า​เป็น​การ์ด',
  ],
  'featureF08Title': [
    'Reports charts',
    'Gráficos do Reports',
    'แผนภูมิ Reports',
  ],
  'featureF08Text': [
    'Add charts from Reports to your note.',
    'Adicione gráficos do Reports à sua anotação.',
    'เพิ่ม​แผนภูมิ​จาก Reports ลงใน​บันทึก',
  ],
  'featureF09Title': ['Tasks', 'Tarefas', 'งาน'],
  'featureF09Text': [
    'Add task cards to your note.',
    'Adicione cartões de tarefa à sua anotação.',
    'เพิ่ม​การ์ด​งาน​ลงใน​บันทึก',
  ],
  'featureF10Title': [
    'Handwriting to text',
    'Escrita à mão para texto',
    'ลายมือ​เป็น​ข้อความ',
  ],
  'featureF10Text': [
    'Request handwriting transcription, review the draft and accept your corrections.',
    'Peça a transcrição da escrita à mão, revise o rascunho e aceite suas correções.',
    'ขอ​ถอด​ลายมือ​เป็น​ข้อความ ตรวจ​ฉบับร่าง และ​ยอมรับ​การ​แก้ไข​ของ​คุณ',
  ],
  'featureF11Title': ['PDF and print', 'PDF e impressão', 'PDF และ​การ​พิมพ์'],
  'featureF11Text': [
    'Export Original or Typed notes as printable PDFs.',
    'Exporte anotações Original ou Digitada como PDFs para imprimir.',
    'ส่งออก​บันทึก​แบบ​ต้นฉบับ​หรือ​แบบ​พิมพ์​เป็น PDF ที่​พิมพ์​ได้',
  ],
  'featureF12Title': ['Quizzes', 'Quizzes', 'แบบทดสอบ'],
  'featureF12Text': [
    'Prepare quizzes from your notes and open them in browser Certifications.',
    'Prepare quizzes a partir das suas anotações e abra no Certifications no navegador.',
    'เตรียม​แบบทดสอบ​จาก​บันทึก แล้ว​เปิด​ใน Certifications บน​เบราว์เซอร์',
  ],
  'featureF13Title': ['Media to text', 'Mídia para texto', 'สื่อ​เป็น​ข้อความ'],
  'featureF13Text': [
    'On request, Cortex turns supported audio, video, PDF and image content into text and study notes. It is off by default.',
    'Quando você pede, o Cortex transforma áudio, vídeo, PDF e imagens compatíveis em texto e notas de estudo. Fica desligado por padrão.',
    'เมื่อคุณ​สั่ง Cortex จะ​แปลง​เสียง วิดีโอ PDF และ​รูปภาพ​ที่​รองรับ​เป็น​ข้อความ​และ​บันทึก​การ​เรียน ค่าเริ่มต้น​คือ​ปิด',
  ],
  'featureF14Title': ['Instant', 'Instant', 'Instant'],
  'featureF14Text': [
    'Share a temporary page by link or code. Anyone with it can edit until the room expires after 15 minutes.',
    'Compartilhe uma página temporária por link ou código. Quem tiver pode editar até a sala expirar, depois de 15 minutos.',
    'แชร์​หน้า​ชั่วคราว​ด้วย​ลิงก์​หรือ​รหัส ทุก​คน​ที่​มี​ลิงก์​แก้ไข​ได้​จน​กว่า​ห้อง​จะ​หมดอายุ​ใน 15 นาที',
  ],
  'featureF15Title': ['Public notes', 'Anotações públicas', 'บันทึก​สาธารณะ'],
  'featureF15Text': [
    'Publish selected reading versions of your notes for everyone to read.',
    'Publique versões de leitura selecionadas das suas anotações para todos lerem.',
    'เผยแพร่​ฉบับ​อ่าน​ที่​เลือก​จาก​บันทึก​ของ​คุณ​ให้​ทุก​คน​อ่าน​ได้',
  ],

  // How it works
  'howTitle': ['How it works', 'Como funciona', 'วิธีการ​ทำงาน'],
  'howNoteTitle': [
    'The life of a note',
    'A vida de uma anotação',
    'เส้นทาง​ของ​บันทึก',
  ],
  'howWriteTitle': ['Write', 'Escrever', 'เขียน'],
  'howWriteText': [
    'Start a note and write on your device. Ordinary writing works without login or internet.',
    'Comece uma anotação e escreva no seu dispositivo. A escrita comum funciona sem login e sem internet.',
    'เริ่ม​บันทึก​และ​เขียน​บน​อุปกรณ์ การ​เขียน​ทั่วไป​ใช้งาน​ได้​โดย​ไม่​ต้อง​ลงชื่อ​เข้าใช้​หรือ​ใช้​อินเทอร์เน็ต',
  ],
  'howSignInTitle': ['Sign in', 'Entrar', 'ลงชื่อ​เข้าใช้'],
  'howSignInText': [
    'Sign in when you want private cloud sync, publication or account-required services.',
    'Entre na conta quando quiser sincronização privada na nuvem, publicação ou serviços que pedem conta.',
    'ลงชื่อ​เข้าใช้​เมื่อ​ต้องการ​ซิงค์​ส่วนตัว​บน​คลาวด์ การ​เผยแพร่ หรือ​บริการ​ที่​ต้องใช้​บัญชี',
  ],
  'howPublishTitle': ['Publish', 'Publicar', 'เผยแพร่'],
  'howPublishText': [
    'Syncing does not publish your note. You publish only the reading versions you select.',
    'Sincronizar não publica sua anotação. Você publica só as versões de leitura que escolher.',
    'การ​ซิงค์​ไม่ได้​เผยแพร่​บันทึก คุณ​เผยแพร่​เฉพาะ​ฉบับ​อ่าน​ที่​เลือก​เท่านั้น',
  ],
  'howInstantTitle': [
    'The life of an Instant room',
    'A vida de uma sala Instant',
    'เส้นทาง​ของ​ห้อง Instant',
  ],
  'howInstantText': [
    'In Instant, share the room link or code. Anyone with it can edit until the room expires. A room needs no login and expires after 15 minutes.',
    'No Instant, compartilhe o link ou o código da sala. Quem tiver pode editar até a sala expirar. A sala não precisa de login e expira depois de 15 minutos.',
    'ใน Instant ให้​แชร์​ลิงก์​หรือ​รหัส​ห้อง ทุก​คน​ที่​มี​ลิงก์​แก้ไข​ได้​จน​กว่า​ห้อง​จะ​หมดอายุ ห้อง​ไม่​ต้อง​ลงชื่อ​เข้าใช้​และ​หมดอายุ​หลังจาก 15 นาที',
  ],
  'howTranscribeTitle': [
    'Handwriting to text',
    'Escrita à mão para texto',
    'ลายมือ​เป็น​ข้อความ',
  ],
  'howTranscribeText': [
    'Transcription requires sign-in and internet, including when the model runs locally. Review its saved draft before accepting it. Acceptance does not publish it.',
    'A transcrição pede login e internet, mesmo quando o modelo roda no seu dispositivo. Revise o rascunho salvo antes de aceitar. Aceitar não publica.',
    'การ​ถอด​ข้อความ​ต้อง​ลงชื่อ​เข้าใช้​และ​ใช้​อินเทอร์เน็ต แม้​โมเดล​จะ​ทำงาน​ใน​เครื่อง ตรวจ​ฉบับร่าง​ที่​บันทึก​ไว้​ก่อน​ยอมรับ การ​ยอมรับ​ไม่ได้​เผยแพร่',
  ],
  'howWhereTitle': [
    'Where notes live',
    'Onde ficam as anotações',
    'บันทึก​อยู่​ที่​ไหน',
  ],
  'howLocalTitle': [
    'On your device',
    'No seu dispositivo',
    'ใน​อุปกรณ์​ของ​คุณ',
  ],
  'howLocalText': [
    'A note stays on your device and works offline.',
    'A anotação fica no seu dispositivo e funciona sem internet.',
    'บันทึก​อยู่​ใน​อุปกรณ์​และ​ใช้งาน​ออฟไลน์​ได้',
  ],
  'howSyncTitle': ['Private sync', 'Sincronização privada', 'ซิงค์​ส่วนตัว'],
  'howSyncText': [
    'You choose to sync a note. A synced note stays private.',
    'Você escolhe sincronizar uma anotação. A anotação sincronizada continua privada.',
    'คุณ​เลือก​ซิงค์​บันทึก​เอง บันทึก​ที่​ซิงค์​ยังคง​เป็น​ส่วนตัว',
  ],
  'howPublicTitle': ['Public', 'Pública', 'สาธารณะ'],
  'howPublicText': [
    'Only the reading versions you publish are public.',
    'Só as versões de leitura que você publica são públicas.',
    'เฉพาะ​ฉบับ​อ่าน​ที่​คุณ​เผยแพร่​เท่านั้น​ที่​เป็น​สาธารณะ',
  ],
  'faqTitle': ['Questions', 'Perguntas', 'คำถาม'],
  'faqLoginQ': [
    'Do I need an account to write?',
    'Preciso de conta para escrever?',
    'ต้อง​มี​บัญชี​เพื่อ​เขียน​ไหม',
  ],
  'faqLoginA': [
    'No. Ordinary writing works without login or internet.',
    'Não. A escrita comum funciona sem login e sem internet.',
    'ไม่​ต้อง การ​เขียน​ทั่วไป​ใช้งาน​ได้​โดย​ไม่​ต้อง​ลงชื่อ​เข้าใช้​หรือ​ใช้​อินเทอร์เน็ต',
  ],
  'faqSyncQ': [
    'Does sync publish my note?',
    'Sincronizar publica minha anotação?',
    'การ​ซิงค์​เผยแพร่​บันทึก​ของ​ฉัน​ไหม',
  ],
  'faqSyncA': [
    'No. Syncing does not publish your note.',
    'Não. Sincronizar não publica sua anotação.',
    'ไม่ การ​ซิงค์​ไม่ได้​เผยแพร่​บันทึก',
  ],
  'faqInstantQ': [
    'How long does an Instant room last?',
    'Quanto tempo dura uma sala Instant?',
    'ห้อง Instant อยู่ได้​นาน​เท่าไร',
  ],
  'faqInstantA': [
    '15 minutes. Anyone with the link or code can edit until then.',
    '15 minutos. Até lá, quem tiver o link ou o código pode editar.',
    '15 นาที ทุก​คน​ที่​มี​ลิงก์​หรือ​รหัส​แก้ไข​ได้​จนถึง​ตอนนั้น',
  ],
  'faqBrowserQ': [
    'Can I write notes in the browser?',
    'Posso escrever anotações no navegador?',
    'เขียน​บันทึก​ใน​เบราว์เซอร์​ได้​ไหม',
  ],
  'faqBrowserA': [
    'The browser reads public notes, opens Instant and shows your synced notes read only after sign-in.',
    'O navegador lê anotações públicas, abre o Instant e mostra suas anotações sincronizadas só para leitura depois do login.',
    'เบราว์เซอร์​อ่าน​บันทึก​สาธารณะ เปิด Instant และ​แสดง​บันทึก​ที่​ซิงค์​ไว้​แบบ​อ่าน​อย่าง​เดียว​หลัง​ลงชื่อ​เข้าใช้',
  ],
  'faqTrainingQ': [
    'Is my note content used for training?',
    'O conteúdo das minhas anotações é usado para treino?',
    'เนื้อหา​บันทึก​ของ​ฉัน​ถูก​ใช้​ฝึก​โมเดล​ไหม',
  ],
  'faqTrainingA': [
    'Yes. We use note content and transcription corrections to train and improve our models. Private notes remain hidden from other users.',
    'Sim. Usamos o conteúdo das anotações e as correções de transcrição para treinar e melhorar nossos modelos. Anotações privadas continuam ocultas para outros usuários.',
    'ใช่ เรา​ใช้​เนื้อหา​บันทึก​และ​การ​แก้ไข​การ​ถอด​ข้อความ​เพื่อ​ฝึก​และ​ปรับปรุง​โมเดล บันทึก​ส่วนตัว​ยังคง​ซ่อน​จาก​ผู้ใช้​อื่น',
  ],

  // Engineering
  'engTitle': ['Engineering', 'Engenharia', 'วิศวกรรม'],
  'engLead': [
    'Annotations uses a shared editor across supported platforms. The application checks editing rules locally. The server checks submitted content and permissions.',
    'O Annotations usa um editor compartilhado nas plataformas suportadas. O aplicativo verifica as regras de edição no dispositivo. O servidor verifica o conteúdo enviado e as permissões.',
    'Annotations ใช้​ตัวแก้ไข​เดียวกัน​ใน​ทุก​แพลตฟอร์ม​ที่​รองรับ แอป​ตรวจ​กฎ​การ​แก้ไข​ใน​เครื่อง เซิร์ฟเวอร์​ตรวจ​เนื้อหา​ที่​ส่ง​มา​และ​สิทธิ์',
  ],
  'engArchitectureTitle': ['Architecture', 'Arquitetura', 'สถาปัตยกรรม'],
  'engArchitectureText': [
    'Each part links to its public source at a tagged version.',
    'Cada parte leva ao código público em uma versão marcada.',
    'แต่ละ​ส่วน​ลิงก์​ไป​ยัง​ซอร์ส​สาธารณะ​ใน​เวอร์ชัน​ที่​ติด​แท็ก',
  ],
  'engRulesTitle': ['Editor rules', 'Regras do editor', 'กฎ​ของ​ตัวแก้ไข'],
  'engRulesText': [
    'The application checks editing rules locally, so writing works offline. The server checks submitted content and permissions again.',
    'O aplicativo verifica as regras de edição no dispositivo, então a escrita funciona sem internet. O servidor verifica de novo o conteúdo enviado e as permissões.',
    'แอป​ตรวจ​กฎ​การ​แก้ไข​ใน​เครื่อง จึง​เขียน​แบบ​ออฟไลน์​ได้ เซิร์ฟเวอร์​ตรวจ​เนื้อหา​ที่​ส่ง​มา​และ​สิทธิ์​อีก​ครั้ง',
  ],
  'engSourceTitle': ['Open source', 'Código aberto', 'โอเพนซอร์ส'],
  'engSourceText': [
    'The application source code is public.',
    'O código do aplicativo é público.',
    'ซอร์ส​โค้ด​ของ​แอป​เป็น​สาธารณะ',
  ],
  'engModelTitle': [
    'Our own model',
    'Nosso próprio modelo',
    'โมเดล​ของ​เรา​เอง',
  ],
  'engModelText': [
    'Our handwriting model improves through checked training batches and language-specific evaluation in English, Brazilian Portuguese and Thai.',
    'Nosso modelo de escrita à mão melhora com lotes de treino verificados e avaliação por idioma em inglês, português do Brasil e tailandês.',
    'โมเดล​ลายมือ​ของ​เรา​พัฒนา​ผ่าน​ชุด​ข้อมูล​ฝึก​ที่​ตรวจ​แล้ว​และ​การ​ประเมิน​แยก​ตาม​ภาษา ทั้ง​อังกฤษ โปรตุเกส​บราซิล และ​ไทย',
  ],
  'engTrackingTitle': [
    'Usage tracking',
    'Rastreamento de uso',
    'การ​ติดตาม​การ​ใช้งาน',
  ],
  'engTrackingText': [
    'Usage tracking does not include note content.',
    'O rastreamento de uso não inclui o conteúdo das anotações.',
    'การ​ติดตาม​การ​ใช้งาน​ไม่​รวม​เนื้อหา​บันทึก',
  ],
  'diagramApps': [
    'Apps: Mac, Linux, iPad, Android, browser',
    'Apps: Mac, Linux, iPad, Android, navegador',
    'แอป: Mac, Linux, iPad, Android, เบราว์เซอร์',
  ],
  'diagramGateway': ['Gateway', 'Gateway', 'เกตเวย์'],
  'diagramNotesApi': ['Notes API', 'API de anotações', 'API บันทึก'],
  'diagramFiles': [
    'File storage',
    'Armazenamento de arquivos',
    'ที่​เก็บ​ไฟล์',
  ],
  'diagramReports': ['Reports', 'Reports', 'Reports'],
  'diagramCertifications': [
    'Certifications',
    'Certifications',
    'Certifications',
  ],
  'diagramCortex': ['Cortex', 'Cortex', 'Cortex'],
  'diagramTracking': [
    'Usage events, no note content',
    'Eventos de uso, sem conteúdo',
    'เหตุการณ์​การ​ใช้งาน ไม่​มี​เนื้อหา​บันทึก',
  ],
  'diagramDeviceRules': [
    'Your device checks the editor rules',
    'Seu dispositivo verifica as regras',
    'อุปกรณ์​ของ​คุณ​ตรวจ​กฎ​ของ​ตัวแก้ไข',
  ],
  'diagramServerRules': [
    'The server checks content and permissions',
    'O servidor verifica conteúdo e permissões',
    'เซิร์ฟเวอร์​ตรวจ​เนื้อหา​และ​สิทธิ์',
  ],
  'diagramCorrections': [
    'Your corrections',
    'Suas correções',
    'การ​แก้ไข​ของ​คุณ',
  ],
  'diagramBatches': [
    'Checked training batches',
    'Lotes de treino verificados',
    'ชุด​ข้อมูล​ฝึก​ที่​ตรวจ​แล้ว',
  ],
  'diagramLanguageTests': [
    'Tests per language: EN, PT, TH',
    'Testes por idioma: EN, PT, TH',
    'ทดสอบ​แยก​ภาษา: EN, PT, TH',
  ],
  'diagramModelVersion': [
    'A new model version',
    'Uma nova versão do modelo',
    'โมเดล​เวอร์ชัน​ใหม่',
  ],

  // Download
  'downloadTitle': ['Download', 'Baixar', 'ดาวน์โหลด'],
  'downloadLead': [
    'Choose your platform for installation and update instructions.',
    'Escolha sua plataforma para ver as instruções de instalação e atualização.',
    'เลือก​แพลตฟอร์ม​ของ​คุณ​เพื่อ​ดู​วิธี​ติดตั้ง​และ​อัปเดต',
  ],
  'downloadSource': [
    'Application source code is public. Official model downloads require an Asodya account. The training dataset is not distributed.',
    'O código do aplicativo é público. Baixar os modelos oficiais exige uma conta Asodya. O conjunto de dados de treino não é distribuído.',
    'ซอร์ส​โค้ด​ของ​แอป​เป็น​สาธารณะ การ​ดาวน์โหลด​โมเดล​ทางการ​ต้องใช้​บัญชี Asodya ชุด​ข้อมูล​ฝึก​ไม่ได้​เผยแพร่',
  ],
  'platformMac': ['Mac', 'Mac', 'Mac'],
  'platformLinux': ['Linux', 'Linux', 'Linux'],
  'platformAndroid': ['Android', 'Android', 'Android'],
  'platformIos': ['iPhone and iPad', 'iPhone e iPad', 'iPhone และ iPad'],
  'statusNoRelease': [
    'No public release yet.',
    'Ainda não há versão pública.',
    'ยัง​ไม่​มี​รุ่น​สาธารณะ',
  ],
  'statusReleased': ['Available', 'Disponível', 'พร้อม​ใช้งาน'],
  'statusIos': [
    'Not available to the public yet.',
    'Ainda não está disponível ao público.',
    'ยัง​ไม่​เปิด​ให้​ใช้งาน​แบบ​สาธารณะ',
  ],
  'releaseVersion': ['Version', 'Versão', 'เวอร์ชัน'],
  'releaseDate': ['Date', 'Data', 'วันที่'],
  'releaseChecksum': ['SHA-256', 'SHA-256', 'SHA-256'],
  'installCommand': ['Install', 'Instalar', 'ติดตั้ง'],
  'sourceCommand': ['Public source', 'Código público', 'ซอร์ส​สาธารณะ'],
  'copyCommand': ['Copy command', 'Copiar comando', 'คัดลอก​คำสั่ง'],
  'commandCopied': ['Command copied', 'Comando copiado', 'คัดลอก​คำสั่ง​แล้ว'],
  'androidStepsTitle': [
    'Install steps',
    'Passos de instalação',
    'ขั้นตอน​การ​ติดตั้ง',
  ],
  'androidStep1': [
    'Open the release page and download the APK file.',
    'Abra a página de versões e baixe o arquivo APK.',
    'เปิด​หน้ารุ่น​และ​ดาวน์โหลด​ไฟล์ APK',
  ],
  'androidStep2': [
    'Allow installs from this source when Android asks.',
    'Permita instalações desta origem quando o Android pedir.',
    'อนุญาต​การ​ติดตั้ง​จาก​แหล่ง​นี้​เมื่อ Android ถาม',
  ],
  'androidStep3': [
    'Open the file and install.',
    'Abra o arquivo e instale.',
    'เปิด​ไฟล์​แล้ว​ติดตั้ง',
  ],
  'releasesPage': ['Release page', 'Página de versões', 'หน้ารุ่น'],
  'updateTitle': ['Updates', 'Atualizações', 'การ​อัปเดต'],
  'updateText': [
    'To update, follow the same steps with the newest release.',
    'Para atualizar, siga os mesmos passos com a versão mais nova.',
    'หาก​ต้องการ​อัปเดต ให้​ทำ​ตาม​ขั้นตอน​เดิม​กับ​รุ่น​ล่าสุด',
  ],
  'repoLink': ['Source on GitHub', 'Código no GitHub', 'ซอร์ส​บน GitHub'],

  // Footer
  'footerApiDocs': ['API docs', 'Documentação da API', 'เอกสาร API'],
  'footerSource': ['Public source', 'Código público', 'ซอร์ส​สาธารณะ'],
  'footerBuild': ['Build', 'Versão', 'บิลด์'],

  // Redesign (annotations#53, owner direction 2026-11-20)
  'heroBefore': [
    'Write, organize and review your study ',
    'Escreva, organize e revise suas ',
    'เขียน​ จัด​ระเบียบ​ และ​ทบทวน',
  ],
  'heroWord': ['notes', 'anotações', 'บันทึก'],
  'heroAfter': ['.', ' de estudo.', 'การ​เรียน​ของ​คุณ'],
  'showcaseLabel': [
    'The app on each platform',
    'O aplicativo em cada plataforma',
    'แอป​บน​แต่ละ​แพลตฟอร์ม',
  ],
  'showMac': ['Mac', 'Mac', 'Mac'],
  'showLinux': ['Linux', 'Linux', 'Linux'],
  'showBrowser': ['Browser', 'Navegador', 'เบราว์เซอร์'],
  'installTitle': [
    'Install Annotations',
    'Instale o Annotations',
    'ติดตั้ง​ Annotations',
  ],
  'platformTablets': [
    'iPad and Android tablets',
    'iPad e tablets Android',
    'iPad​ และ​แท็บเล็ต​ Android',
  ],
  'platformAndroidPhones': [
    'Android phones',
    'Celulares Android',
    'โทรศัพท์​ Android',
  ],
  'platformIphone': ['iPhone', 'iPhone', 'iPhone'],
  'platformWeb': ['Browser', 'Navegador', 'เบราว์เซอร์'],
  'statusWeb': ['Available now.', 'Disponível agora.', 'ใช้​งาน​ได้​แล้ว'],
  'actionOpenWeb': [
    'Open in the browser',
    'Abrir no navegador',
    'เปิด​ใน​เบราว์เซอร์',
  ],
  'howToInstall': ['How to install', 'Como instalar', 'วิธี​ติดตั้ง'],
  'copyAddress': ['Copy address', 'Copiar endereço', 'คัดลอก​ที่​อยู่'],
  'addressCopied': [
    'Address copied',
    'Endereço copiado',
    'คัดลอก​ที่​อยู่​แล้ว',
  ],
  'installSeparately': [
    'Each app is installed on its own device.',
    'Cada aplicativo é instalado no seu próprio dispositivo.',
    'แต่ละ​แอป​ติดตั้ง​แยก​บน​อุปกรณ์​ของ​ตัว​เอง',
  ],
  'allFeatures': ['All features', 'Todos os recursos', 'ฟีเจอร์​ทั้งหมด'],
  'stepsTitle': [
    'Install steps',
    'Passos de instalação',
    'ขั้น​ตอน​การ​ติดตั้ง',
  ],
  'diagramDraft': [
    'A saved draft',
    'Um rascunho salvo',
    'ฉบับ​ร่าง​ที่​บันทึก​ไว้',
  ],
  'diagramReview': ['You review it', 'Você revisa', 'คุณ​ตรวจ'],
  'diagramAccept': [
    'You accept it, unpublished',
    'Você aceita, sem publicar',
    'คุณ​ยอมรับ​ ไม่​เผยแพร่',
  ],
  'diagramWrite': [
    'Write on your device',
    'Escreva no dispositivo',
    'เขียน​บน​อุปกรณ์',
  ],
  'diagramSignIn': [
    'Sign in to sync',
    'Entre para sincronizar',
    'ลงชื่อ​เข้าใช้​เพื่อ​ซิงค์',
  ],
  'diagramPublish': [
    'Publish what you choose',
    'Publique o que escolher',
    'เผยแพร่​สิ่ง​ที่​คุณ​เลือก',
  ],
};
