// ÁXIS · conexão com a nuvem (Supabase).
// A chave publicável foi feita para ficar no app: quem protege os dados são as regras do banco (RLS).
// (self = window no app e = service worker, que também lê este arquivo)
self.AXIS_CONFIG = {
  supabaseUrl: 'https://qlksntoamjutmycrqidf.supabase.co',
  supabaseKey: 'sb_publishable_VgJ5ctbzboJu8qXTYZnWCQ_8ZvKqVIC',
  // Chave pública das notificações (a privada fica guardada no Supabase)
  vapidPublicKey: 'BNevmXcqE7YjbsKCFvmI6MOiZQbZAc7ZhwocT6e6bcuY3ci2kZwy5VzuMAVGFSns1v4eD_VkZwwGK5_J886MP-A'
};
