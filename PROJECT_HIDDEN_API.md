# Tích hợp giao diện ẩn Project (Supabase Local)

Workspace này hiện chỉ có schema, migration và kiểm thử; chưa có mã ứng dụng để gắn giao diện. Tài liệu này mô tả hợp đồng HTTP đã được kiểm thử để áp dụng trong ứng dụng khi có vị trí mã nguồn.

## Đọc danh sách và chi tiết

Gọi PostgREST bằng JWT của người dùng đang đăng nhập và anon key của Supabase Local. Ví dụ:

```http
GET http://127.0.0.1:54321/rest/v1/projects?company_id=eq.<company-uuid>&select=id,name,is_hidden,updated_at
Authorization: Bearer <user-access-token>
apikey: <local-anon-key>
```

RLS tự lọc theo tenant, tư cách thành viên, Role và trạng thái ẩn. Owner/Admin có thể thấy Project ẩn; các Role khác nhận danh sách không chứa Project ẩn. Không dùng service-role key trong client, không tự lọc ẩn ở phía trình duyệt để thay thế RLS. Một truy vấn chi tiết trả mảng rỗng có thể là bản ghi không tồn tại **hoặc** người dùng không có quyền xem; giao diện nên dùng thông báo chung “Không tìm thấy hoặc không có quyền truy cập”.

Giao diện Owner/Admin có thể hiển thị bộ lọc `is_hidden=eq.true` hoặc `is_hidden=eq.false`. Giao diện Role khác không hiển thị nút ẩn/bỏ ẩn; quyền thực thi vẫn do RPC bảo vệ ở database.

## Ẩn hoặc bỏ ẩn

```http
POST http://127.0.0.1:54321/rest/v1/rpc/set_project_hidden
Authorization: Bearer <user-access-token>
apikey: <local-anon-key>
Content-Type: application/json

{"p_company":"<company-uuid>","p_project":"<project-uuid>","p_hidden":true}
```

Truyền `false` để bỏ ẩn. RPC trả `204 No Content` khi thành công, kể cả nếu Project đã ở trạng thái yêu cầu. Sau `204`, tải lại danh sách và chi tiết từ server để thấy quyền truy cập hiện tại. Không gửi `PATCH projects.is_hidden` hoặc `DELETE projects`: cả hai đều không phải thao tác nghiệp vụ được hỗ trợ.

Chỉ Owner/Admin active cùng tenant có thể gọi RPC, và thuê bao phải cho phép ghi. `403` là từ chối quyền/trạng thái thuê bao/Project không thuộc phạm vi; `400` với mã PostgreSQL `22023` là `p_hidden` không phải giá trị boolean tường minh. Client không nên suy ra nguyên nhân chi tiết từ `403` hoặc thử lại bằng quyền cao hơn.

Ẩn không xóa dữ liệu và không giải phóng quota. Các bảng con và thông báo gắn Project ẩn theo cùng phạm vi Owner/Admin. Lead và Quote nguồn giữ phạm vi truy cập riêng. Bỏ ẩn khôi phục quyền xem theo Role và thành viên hiện có; không tái tạo dữ liệu. Trạng thái thuê bao read-only có thể cho Owner/Admin xem nhưng chặn ẩn/bỏ ẩn.

## Kiểm tra khi nối giao diện

1. Owner/Admin xem Project ẩn trong danh sách và chi tiết, đổi trạng thái hai chiều, thấy trạng thái mới sau tải lại.
2. Thành viên thông thường đang mở Project mất quyền xem chi tiết và bảng con ngay khi ẩn; sau bỏ ẩn quyền cũ trở lại. Thông báo Project ẩn không xuất hiện trong inbox của họ.
3. URL chi tiết cũ của User thường xử lý mảng rỗng an toàn. Nút ẩn/bỏ ẩn không xuất hiện với họ, và gọi RPC thủ công vẫn bị `403`.
4. Project ẩn vẫn chiếm quota; UI quota không trừ số Project ẩn. Kiểm tra read-only, tài khoản inactive và tenant khác.

Kiểm chứng database hiện tại: `npm run test:integration` đạt 1058/1058, `npm run db:test` đạt 157/157, `npm run db:lint` và `npm run check` đạt trên Supabase Local ngày 24/09/2026. Kiểm thử giao diện thực tế chưa thể chạy cho đến khi có mã ứng dụng.
