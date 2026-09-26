> Cập nhật hiện tại: xem mục “Lead và Project sau migration 011” ở cuối file.

# Ứng dụng Project · Supabase Local

Ứng dụng web nhỏ, không cần framework/build, phục vụ bước đầu của màn hình Project. Máy chủ Node chỉ mở tại `127.0.0.1:4173`, lấy API URL và anon key từ CLI Supabase Local của đúng project `project_saas_local`. Browser gọi Auth và PostgREST trực tiếp bằng JWT của người dùng; không dùng service-role key. Phiên đăng nhập ở `sessionStorage` và được refresh khi gần hết hạn.

Giao diện dùng **Inter Variable** cho cả tiêu đề và nội dung. Ba subset Latin, Latin Extended và Vietnamese được phục vụ local từ gói `@fontsource-variable/inter`; không tải font từ CDN khi mở trang.

Ứng dụng có đăng nhập, danh sách và chi tiết Project, tìm kiếm, bộ lọc đang hiển thị/đã ẩn cho Owner/Admin, hộp xác nhận ẩn/bỏ ẩn và tải lại dữ liệu sau RPC. Mọi quyền truy cập do RLS/RPC ở database quyết định. Chưa có màn hình tạo Lead/Quote/Project, onboarding nhân viên hoặc các module nghiệp vụ khác.

## Chạy trên máy local

1. Mở Docker Desktop và chạy `npm run local:start` tại thư mục gốc.
2. Nếu database local đang trống và muốn dữ liệu mẫu, chạy `npm run app:demo -- --local-only`. Lệnh **không reset** database; nó từ chối nếu đã có company. Nó tạo một Owner, một Sales và ba Project (một Project ẩn), rồi in thông tin đăng nhập mẫu một lần trong terminal. Chỉ dùng tài khoản mẫu trên database local.
3. Chạy `npm run app:start` rồi mở `http://127.0.0.1:4173`.

Đăng nhập bằng tài khoản đã tồn tại trong Supabase Auth **và** có hàng tương ứng trong `public.users`. Đăng ký Auth tự phát chưa tạo company/User nghiệp vụ; ứng dụng chỉ có đăng nhập. Database local trống sẽ không có Project hoặc tài khoản sử dụng được cho đến khi provisioning dữ liệu.

## Kiểm tra giao diện

- Owner xem cả ba Project, có tab “Đã ẩn”, mở Project và ẩn/bỏ ẩn qua hộp xác nhận.
- Sales chỉ thấy Project đang hiển thị dù đã là thành viên của Project ẩn; gọi RPC trực tiếp vẫn bị từ chối bởi database.
- Ẩn Project không xóa hay giảm quota. Bỏ ẩn trả lại phạm vi truy cập theo tư cách thành viên.
- Nếu truy cập bản ghi không có quyền, giao diện dùng thông báo chung, không tiết lộ sự tồn tại của Project ẩn.

Ngày 25/09/2026, đã chạy Supabase Local, tạo dữ liệu mẫu và kiểm tra giao diện trên trình duyệt: Owner đăng nhập, thấy Project ẩn, bỏ ẩn rồi ẩn lại; Sales đăng nhập, chỉ thấy hai Project đang hiển thị và không có nút ẩn/bỏ ẩn. Thanh tiến độ 0% đã được sửa sau khi phát hiện CSP chặn kiểu inline. `npm run check`, `npm run db:lint` và 157/157 pgTAP đạt sau đó; dữ liệu mẫu vẫn còn. Kết quả 1058 HTTP trong README gốc là bộ kiểm thử database trước khi tạo ứng dụng, không phải bộ kiểm thử giao diện đầy đủ.

## Build Flow — 26/09/2026

Trang danh sách đã đổi sang bảng theo thiết kế, thêm thống kê, bộ lọc, 20/50 dòng, tạo từ Lead cho quyền có thể xác minh, xuất XLSX. Xem `../BUILD_FLOW_PROJECT_LIST.md` để biết chính xác phần hoàn tất và phụ thuộc backend; đặc biệt nút tạo cho role thường và quá hạn tổng hợp chưa đầy đủ. Không dùng dữ liệu minh họa trong mã giao diện.

`npm run app:check` kiểm tra cú pháp; `npm run app:test` chạy logic danh sách. Kiểm thử browser riêng dùng Supabase local trống và tạo fixture; xem hướng dẫn trong báo cáo. 176 pgTAP và kiểm thử browser Owner/Sales ở 1536/1366/1280 đã đạt ngày 26/09/2026. Database được reset sau kiểm thử nên thông tin tài khoản demo của các lượt trước không còn dùng được.

## Lead và Project sau migration 011

Giao diện hiện có trang Lead để tạo/sửa những trường mới, gồm bộ chọn option ＋/×; nút Lead trên sidebar mở trang này khi có quyền. Mỗi Lead và Project có một ngân sách nhập tay; Project sửa tại trang chi tiết hoặc ngay từ Lead nguồn nếu được phép. Xem `../BUILD_FLOW_LEAD_FIELDS.md`. Hướng dẫn đầu file mô tả phiên bản ứng dụng cũ; dùng phần này cho tính năng mới.
